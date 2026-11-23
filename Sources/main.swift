import Cocoa
import ApplicationServices
import CoreGraphics
import CryptoKit

// Activity Logger: records what was in front of you, second by second, as encrypted
// JSONL segments in ~/personal-tools/data/activity-logger/YYYY-MM-DD.jsonl.enc. No analysis.
//
// Each row is one segment: a stretch of time where the status, frontmost app,
// window title and (for Chrome) tab URL/title all stayed the same. Rows are sealed with a
// public key (Crypto.swift), so nothing is stored as plain text, and Chrome windows outside
// the one chosen profile, and Incognito windows, are recorded without their title or URL.

// MARK: - Configuration

enum Config {
    /// No keyboard/mouse input for this long means you count as idle.
    static let idleThreshold: TimeInterval = 300
    /// How often the frontmost app / window / tab is sampled.
    static let pollInterval: TimeInterval = 1
    /// Long unchanged segments are split so a crash loses at most this much.
    static let maxSegment: TimeInterval = 300
    static let chromeBundle = "com.google.Chrome"
    static let loggerVersion = "1.1"
}

// MARK: - Formatting helpers

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone.current
    return f
}()

let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func orNull(_ s: String?) -> Any { s ?? NSNull() }

/// Seconds rounded to 0.1, as a decimal so JSON prints 1.9 rather than 1.8999999999999999.
func seconds(_ t: TimeInterval) -> NSDecimalNumber {
    NSDecimalNumber(string: String(format: "%.1f", t), locale: Locale(identifier: "en_US_POSIX"))
}

// MARK: - Snapshot

struct Snapshot: Equatable {
    var status: String          // "active" | "idle" | "locked"
    var app: String?
    var bundleID: String?
    var windowTitle: String?
    var url: String?
    var tabTitle: String?
    /// True for a Chrome window outside the chosen profile: its title and URL are withheld.
    var isPrivate = false
}

// MARK: - Logger

final class ActivityLogger {
    private var current: Snapshot?
    private var segmentStart = Date()
    private var locked = false
    private var asleepSince: Date?
    private var timer: Timer?
    private var chromeScript: NSAppleScript?
    private var settings = LoggerConfig()
    private var publicKey: Curve25519.KeyAgreement.PublicKey?
    private var settingsStamp: Date?
    private var chromeStamp: Date?
    private var chromeMode = ChromeMode.unset
    /// Every label any of Chrome's profiles could show. Only these are ever written to errors.log.
    private var knownLabels = Set<String>()
    private var notes = Set<String>()

    /// Writes a line to errors.log (stderr), once per distinct message. Never includes titles or URLs.
    private func note(_ message: String) {
        guard notes.insert(message).inserted else { return }
        FileHandle.standardError.write(Data("\(isoFormatter.string(from: Date())) \(message)\n".utf8))
    }

    private func modified(_ url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? Date.distantPast
    }

    /// Re-reads config.json and Chrome's profile list when either changes, so `set-profile`
    /// applies without a restart and a renamed or added profile is taken into account.
    private func reloadSettingsIfChanged() {
        let stamp = modified(Paths.configFile)
        let chrome = modified(chromeLocalState)
        if stamp == settingsStamp && chrome == chromeStamp { return }
        let firstLoad = settingsStamp == nil
        let oldKey = settings.publicKey
        settingsStamp = stamp
        chromeStamp = chrome
        settings = LoggerConfig.load()
        publicKey = settings.publicKey.flatMap { LogCrypto.publicKey(base64: $0) }
        let profiles = loadChromeProfiles()
        chromeMode = settings.chromeMode(profiles: profiles)
        knownLabels = Set(profiles.flatMap { $0.candidateLabels })
        notes.removeAll()
        if publicKey == nil {
            note("No encryption key in config.json, so nothing is being logged. Run `activity-logger setup`.")
        } else if !firstLoad && oldKey != settings.publicKey {
            note("The encryption key in config.json changed. If you didn't run `activity-logger setup --new-key`, run `activity-logger status`.")
        }
        if let vault = KeyVault.load(), vault.publicKey != settings.publicKey, publicKey != nil {
            note("config.json names a different encryption key than key.json, so new rows can't be read back. Run `activity-logger setup`.")
        }
    }

    func start() {
        Paths.ensureLogDir()
        reloadSettingsIfChanged()
        // The lock notifications only report changes, so ask once whether the screen is locked right now.
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           (session["CGSSessionScreenIsLocked"] as? Bool) == true {
            locked = true
        }

        // Ask for Accessibility (needed for window titles). Shows the system prompt once.
        let prompt = ProcessInfo.processInfo.environment["ACTIVITY_LOGGER_NO_PROMPT"] == nil
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        writeMarker("logger_start", extra: ["accessibility_granted": trusted, "version": Config.loggerVersion])

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tick()
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.willSleep()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.didWake()
        }
        ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            self?.shutdown(reason: "power_off")
        }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true
            self?.tick()
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false
            self?.tick()
        }

        let t = Timer(timeInterval: Config.pollInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: Sampling

    func tick() {
        reloadSettingsIfChanged()
        if asleepSince != nil { return }
        let now = Date()
        let snap = sample()

        guard let cur = current else {
            openSegment(snap, at: now)
            return
        }

        if snap != cur {
            var boundary = now
            // Going idle: the idle stretch really began at the last input, so backdate it.
            if snap.status == "idle" && cur.status == "active" {
                boundary = max(segmentStart, now.addingTimeInterval(-idleSeconds()))
            }
            closeSegment(at: boundary)
            openSegment(snap, at: boundary)
        } else if !Calendar.current.isDate(segmentStart, inSameDayAs: now) {
            // Split at local midnight so each day file is self-contained.
            let midnight = Calendar.current.startOfDay(for: now)
            closeSegment(at: midnight)
            openSegment(cur, at: midnight)
        } else if now.timeIntervalSince(segmentStart) >= Config.maxSegment {
            closeSegment(at: now)
            openSegment(cur, at: now)
        }
    }

    private func sample() -> Snapshot {
        if locked {
            return Snapshot(status: "locked", app: nil, bundleID: nil, windowTitle: nil, url: nil, tabTitle: nil)
        }
        let status = idleSeconds() >= Config.idleThreshold ? "idle" : "active"
        let front = NSWorkspace.shared.frontmostApplication
        var snap = Snapshot(status: status,
                            app: front?.localizedName,
                            bundleID: front?.bundleIdentifier,
                            windowTitle: nil, url: nil, tabTitle: nil)
        if let pid = front?.processIdentifier {
            snap.windowTitle = focusedWindowTitle(pid: pid)
        }
        if let bundle = front?.bundleIdentifier, let pid = front?.processIdentifier,
           bundle == Config.chromeBundle || bundle.hasPrefix(Config.chromeBundle + ".") {
            // The second form covers Chrome Beta and Canary and web apps installed from Chrome.
            sampleChrome(into: &snap, pid: pid, isChromeItself: bundle == Config.chromeBundle)
        }
        return snap
    }

    /// Adds the Chrome tab's URL and title, or withholds everything about the window.
    ///
    /// With one profile chosen, a window is logged only when Chrome's own label at the end of
    /// its title names that profile. Anything else (another profile, Incognito, a title that
    /// can't be read, Chrome Beta or a Chrome web app, no choice made yet) is recorded as
    /// Chrome with no title and no URL. Incognito is withheld in every mode.
    private func sampleChrome(into snap: inout Snapshot, pid: pid_t, isChromeItself: Bool) {
        func withhold() {
            snap.windowTitle = nil
            snap.url = nil
            snap.tabTitle = nil
            snap.isPrivate = true
        }
        let allowed: [String]
        switch chromeMode {
        case .unset:
            note("No Chrome profile chosen yet, so Chrome is recorded without details. Run `activity-logger set-profile`.")
            return withhold()
        case .all:
            guard isChromeItself else { return }   // other Chrome apps: window title only, as for any app
            guard let tab = chromeActiveTab() else { return }
            if tab.mode == "incognito" { return withhold() }
            snap.url = tab.url
            snap.tabTitle = tab.title
            return
        case .profile(let labels):
            allowed = labels
        }
        guard isChromeItself else {
            note("Chrome Beta, Canary and Chrome web apps can't be matched to a profile, so they are recorded without details.")
            return withhold()
        }
        if allowed.isEmpty {
            note("The chosen Chrome profile can't be told apart from another by name (or no longer exists), so Chrome is recorded without details. Run `activity-logger profiles`.")
            return withhold()
        }
        guard let title = snap.windowTitle else {
            note("Chrome's window title can't be read (is Accessibility allowed?), so Chrome is recorded without details.")
            return withhold()
        }
        guard let label = chromeProfileLabel(fromWindowTitle: title) else {
            note("A Chrome window title had no profile label, so it was recorded without details.")
            return withhold()
        }
        guard allowed.contains(label) else {
            if label.isEmpty {
                note("Chrome isn't labelling its windows with a profile (it only does with more than one profile), so Chrome is recorded without details.")
            } else if knownLabels.contains(label) {
                note("Chrome windows labelled \"\(label)\" are not the chosen profile and are recorded without details.")
            } else if notes.insert("unrecognized:" + label).inserted {
                // Not a known profile name, so it could be page text. Keep it out of errors.log
                // and put it in the encrypted log, where `export` shows it for troubleshooting.
                note("A Chrome window carried a label that matches no profile name and was recorded without details. Export the logs to see it (rows of type chrome_label_unrecognized).")
                writeMarker("chrome_label_unrecognized", extra: ["label": label])
            }
            return withhold()
        }
        guard let tab = chromeActiveTab() else { return }
        if tab.mode == "incognito" { return withhold() }
        // The tab comes from Chrome's scripting and the label from Accessibility. Keep the URL
        // only when both describe the same window: the window title must not have changed while
        // the tab was read, and it must start with the tab's title followed by Chrome's separator.
        let tabTitle = collapseWhitespace(tab.title)
        guard focusedWindowTitle(pid: pid) == title,
              !tabTitle.isEmpty, collapseWhitespace(title).hasPrefix(tabTitle + " - ") else {
            note("A tab's title didn't match its window's title, so its URL was left out.")
            return
        }
        snap.url = tab.url
        snap.tabTitle = tab.title
    }

    private func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .keyDown, .scrollWheel, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef, CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }

    private func chromeActiveTab() -> (url: String, title: String, mode: String)? {
        if chromeScript == nil {
            chromeScript = NSAppleScript(source: """
            tell application "Google Chrome"
                if (count of windows) is 0 then return {"", "", ""}
                set t to active tab of front window
                return {URL of t, title of t, mode of front window}
            end tell
            """)
        }
        guard let script = chromeScript else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            note("Chrome didn't return its active tab (error \(number)), so URLs are missing. Check System Settings > Privacy & Security > Automation.")
            return nil
        }
        if result.numberOfItems < 2 { return nil }
        let url = result.atIndex(1)?.stringValue ?? ""
        let title = result.atIndex(2)?.stringValue ?? ""
        let mode = result.atIndex(3)?.stringValue ?? ""
        if url.isEmpty && title.isEmpty { return nil }
        return (url, title, mode)
    }

    // MARK: Segments

    private func openSegment(_ snap: Snapshot, at date: Date) {
        current = snap
        segmentStart = date
    }

    private func closeSegment(at end: Date) {
        guard let cur = current else { return }
        current = nil
        let duration = end.timeIntervalSince(segmentStart)
        guard duration > 0.05 else { return }
        writeRow([
            "type": "segment",
            "start": isoFormatter.string(from: segmentStart),
            "end": isoFormatter.string(from: end),
            "duration_s": seconds(duration),
            "status": cur.status,
            "app": orNull(cur.app),
            "bundle_id": orNull(cur.bundleID),
            "window_title": orNull(cur.windowTitle),
            "url": orNull(cur.url),
            "tab_title": orNull(cur.tabTitle),
            "private": cur.isPrivate,
        ], day: segmentStart)
    }

    private func willSleep() {
        let now = Date()
        closeSegment(at: now)
        asleepSince = now
    }

    private func didWake() {
        let now = Date()
        if let since = asleepSince {
            writeRow([
                "type": "segment",
                "start": isoFormatter.string(from: since),
                "end": isoFormatter.string(from: now),
                "duration_s": seconds(now.timeIntervalSince(since)),
                "status": "asleep",
                "app": NSNull(), "bundle_id": NSNull(), "window_title": NSNull(),
                "url": NSNull(), "tab_title": NSNull(), "private": false,
            ], day: since)
        }
        asleepSince = nil
        tick()
    }

    func shutdown(reason: String) {
        if asleepSince == nil { closeSegment(at: Date()) }
        writeMarker("logger_stop", extra: ["reason": reason])
    }

    // MARK: Writing

    private func writeMarker(_ type: String, extra: [String: Any]) {
        let now = Date()
        var row: [String: Any] = ["type": type, "start": isoFormatter.string(from: now)]
        for (k, v) in extra { row[k] = v }
        writeRow(row, day: now)
    }

    private func writeRow(_ row: [String: Any], day: Date) {
        // Without a key nothing is written: rows are never stored as plain text.
        guard let key = publicKey else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: row,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        Paths.ensureLogDir()
        let dayName = dayFormatter.string(from: day)
        let file = Paths.logDir.appendingPathComponent(dayName + Paths.encryptedSuffix)
        do {
            try appendEncryptedRow(data, to: file, day: dayName, key: key)
        } catch {
            note("Couldn't write a row: \(error)")
        }
    }
}

// MARK: - Main

// With arguments this is the command-line tool (setup, set-profile, export...). See CLI.swift.
let cliArguments = Array(CommandLine.arguments.dropFirst())
if !cliArguments.isEmpty { runCLI(cliArguments) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let logger = ActivityLogger()
logger.start()

// Flush the open segment when launchd stops us (logout, uninstall, restart).
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        logger.shutdown(reason: sig == SIGTERM ? "sigterm" : "sigint")
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

app.run()
