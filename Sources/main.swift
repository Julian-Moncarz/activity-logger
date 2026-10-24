import Cocoa
import ApplicationServices
import CoreGraphics

// Activity Logger: records what was in front of you, second by second, as raw
// JSONL segments in ~/personal-tools/data/activity-logger/YYYY-MM-DD.jsonl. No analysis, no filtering.
//
// Each line is one segment: a stretch of time where the status, frontmost app,
// window title and (for Chrome) tab URL/title all stayed the same.

// MARK: - Configuration

enum Config {
    static let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("personal-tools/data/activity-logger", isDirectory: true)
    /// No keyboard/mouse input for this long means you count as idle.
    static let idleThreshold: TimeInterval = 300
    /// How often the frontmost app / window / tab is sampled.
    static let pollInterval: TimeInterval = 1
    /// Long unchanged segments are split so a crash loses at most this much.
    static let maxSegment: TimeInterval = 300
    static let chromeBundle = "com.google.Chrome"
    static let loggerVersion = "1.0"
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
}

// MARK: - Logger

final class ActivityLogger {
    private var current: Snapshot?
    private var segmentStart = Date()
    private var locked = false
    private var asleepSince: Date?
    private var timer: Timer?
    private var chromeScript: NSAppleScript?

    func start() {
        try? FileManager.default.createDirectory(at: Config.logDir, withIntermediateDirectories: true)

        // Ask for Accessibility (needed for window titles). Shows the system prompt once.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
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
        if front?.bundleIdentifier == Config.chromeBundle {
            let tab = chromeActiveTab()
            snap.url = tab?.url
            snap.tabTitle = tab?.title
        }
        return snap
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

    private func chromeActiveTab() -> (url: String, title: String)? {
        if chromeScript == nil {
            chromeScript = NSAppleScript(source: """
            tell application "Google Chrome"
                if (count of windows) is 0 then return {"", ""}
                set t to active tab of front window
                return {URL of t, title of t}
            end tell
            """)
        }
        guard let script = chromeScript else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil || result.numberOfItems < 2 { return nil }
        let url = result.atIndex(1)?.stringValue ?? ""
        let title = result.atIndex(2)?.stringValue ?? ""
        if url.isEmpty && title.isEmpty { return nil }
        return (url, title)
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
                "url": NSNull(), "tab_title": NSNull(),
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
        let file = Config.logDir.appendingPathComponent(dayFormatter.string(from: day) + ".jsonl")
        guard var data = try? JSONSerialization.data(withJSONObject: row,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            try? fm.createDirectory(at: Config.logDir, withIntermediateDirectories: true)
            fm.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}

// MARK: - Main

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
