import Cocoa
import CryptoKit

// Command-line side of the app: setup, choosing the Chrome profile, and reading logs back.
// Running the binary with no arguments starts the logger itself (see main.swift).

func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
func warn(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func fail(_ s: String) -> Never { warn(s); exit(1) }

let usage = """
Activity Logger

  activity-logger export [--days N | --from YYYY-MM-DD [--to YYYY-MM-DD] | --all] [--copy]
      Decrypt logs and print them (default: the last 7 days). Asks for Touch ID or your
      password first. --copy puts them on the clipboard instead, ready to paste into Claude.
  activity-logger profiles
      List this Mac's Chrome profiles.
  activity-logger set-profile <number | name | email | domain>
      Log only that Chrome profile. Other profiles and Incognito are recorded as
      "Google Chrome" with no title or URL.
  activity-logger set-profile --label "<label>"
      Also accept this exact label at the end of a Chrome window title, for when Chrome
      names the chosen profile in a way the logger didn't expect.
  activity-logger set-profile --all
      Log every Chrome profile (Incognito windows still aren't logged).
  activity-logger status
      Show the current setup and any recent problems.
  activity-logger setup
      Create the encryption key, choose a Chrome profile, encrypt any old plain-text logs.
      Add --new-key to replace a lost key (logs written with the old one stay unreadable).
"""

func runCLI(_ args: [String]) -> Never {
    let rest = Array(args.dropFirst())
    switch args[0] {
    case "setup": cmdSetup(rest)
    case "profiles": cmdProfiles()
    case "set-profile": cmdSetProfile(rest)
    case "export": cmdExport(rest)
    case "migrate": cmdMigrate()
    case "status": cmdStatus()
    case "selftest": cmdSelfTest()
    case "help", "-h", "--help": say(usage)
    default: warn(usage); exit(2)
    }
    exit(0)
}

// MARK: - Key

/// Makes sure a key exists: wrapped private half in key.json, public half in config.json.
/// An existing key is never replaced unless `replace` is set.
func ensureKey(replace: Bool) {
    var cfg = LoggerConfig.load()
    do {
        if let vault = KeyVault.load(), !replace {
            if cfg.publicKey != vault.publicKey {
                if cfg.publicKey != nil {
                    warn("Note: config.json named a different key than key.json. Restored the one from key.json. Rows written in between may be unreadable.")
                }
                cfg.publicKey = vault.publicKey
                try cfg.save()
            }
            say("Encryption key: already set up.")
            return
        }
        if FileManager.default.fileExists(atPath: KeyVault.file.path) && !replace {
            fail("key.json exists but can't be read. To start over with a new key, run `activity-logger setup --new-key` (logs written so far stay unreadable).")
        }
        if cfg.publicKey != nil && !replace {
            fail("config.json has an encryption key but key.json (the part needed to read logs back) is missing. Restore key.json, or run `activity-logger setup --new-key` to start a new key (logs written so far stay unreadable).")
        }
        let vault = try KeyVault.create()
        try vault.save()
        cfg.publicKey = vault.publicKey
        try cfg.save()
        say("Encryption key: created. Reading logs back needs Touch ID or your password, on this Mac only.")
    } catch {
        fail("Couldn't set up the encryption key: \(error)")
    }
}

// MARK: - Chrome profile

func printProfiles(_ profiles: [ChromeProfile]) {
    for (i, p) in profiles.enumerated() { say("  \(i + 1)) \(p.display)") }
}

func describeChrome(_ cfg: LoggerConfig, _ profiles: [ChromeProfile]) -> String {
    switch cfg.chromeMode(profiles: profiles) {
    case .unset:
        return "no profile chosen yet, so Chrome is recorded without titles or URLs. Choose with `activity-logger set-profile`."
    case .all:
        return "every profile (Incognito windows are recorded without titles or URLs)"
    case .profile(let labels):
        let name = cfg.chromeProfile ?? cfg.chromeProfileDirectory ?? "the labels set by hand"
        if labels.isEmpty {
            return "only \(name), but it can't be told apart from another profile by name right now, so Chrome is recorded without details. Rename it in Chrome or choose again."
        }
        return "only \(name) (window labels: \(labels.joined(separator: ", "))). Other profiles and Incognito are recorded without titles or URLs."
    }
}

func cmdProfiles() {
    let profiles = loadChromeProfiles()
    if profiles.isEmpty { fail("No Chrome profiles found on this Mac.") }
    printProfiles(profiles)
    say("Chrome: " + describeChrome(LoggerConfig.load(), profiles))
}

func saveOrFail(_ cfg: LoggerConfig) {
    do { try cfg.save() } catch { fail("Couldn't save config.json: \(error)") }
}

func applyProfile(_ p: ChromeProfile, among all: [ChromeProfile]) {
    if uniqueLabels(for: p, among: all).isEmpty {
        fail("\"\(p.display)\" can't be told apart from another profile by name. Rename it in Chrome (Settings > You and Google > Customize your Chrome profile) and try again.")
    }
    var cfg = LoggerConfig.load()
    cfg.chromeAllProfiles = nil
    cfg.chromeProfileDirectory = p.directory
    cfg.chromeProfile = p.shortName
    cfg.chromeExtraLabels = nil
    saveOrFail(cfg)
    say("Chrome: " + describeChrome(cfg, all))
    if all.count < 2 {
        warn("Note: Chrome only labels its windows when there is more than one profile. With a single profile, use `activity-logger set-profile --all`.")
    }
}

func cmdSetProfile(_ args: [String]) {
    guard let first = args.first else { fail("Say which profile. Run `activity-logger profiles` to list them.") }
    var cfg = LoggerConfig.load()
    let profiles = loadChromeProfiles()
    if first == "--all" {
        cfg.chromeAllProfiles = true
        cfg.chromeProfileDirectory = nil
        cfg.chromeProfile = nil
        cfg.chromeExtraLabels = nil
        saveOrFail(cfg)
        say("Chrome: " + describeChrome(cfg, profiles))
        return
    }
    if first == "--label" {
        let labels = Array(args.dropFirst()).filter { $0 != "--label" && !$0.isEmpty }
        if labels.isEmpty { fail("Give the label, for example: activity-logger set-profile --label \"Work\"") }
        // A hand-set label must not be one that another profile could show.
        let others = profiles.filter { $0.directory != cfg.chromeProfileDirectory }
        for l in labels {
            if let clash = others.first(where: { $0.candidateLabels.contains(l) }) {
                fail("\"\(l)\" could also be the label of the profile \"\(clash.shortName)\", so it isn't safe to accept.")
            }
        }
        cfg.chromeAllProfiles = nil
        cfg.chromeExtraLabels = labels
        saveOrFail(cfg)
        say("Chrome: " + describeChrome(cfg, profiles))
        return
    }
    let query = args.joined(separator: " ")
    if let n = Int(query), n >= 1, n <= profiles.count {
        applyProfile(profiles[n - 1], among: profiles)
        return
    }
    let q = query.lowercased()
    let hits = profiles.filter {
        [$0.directory, $0.name, $0.email, $0.domain].contains { !$0.isEmpty && $0.lowercased() == q }
    }
    if hits.count == 1 { applyProfile(hits[0], among: profiles); return }
    warn(hits.isEmpty ? "No Chrome profile matches \"\(query)\". The profiles are:" : "More than one profile matches \"\(query)\":")
    printProfiles(hits.isEmpty ? profiles : hits)
    exit(1)
}

// MARK: - Setup

func cmdSetup(_ args: [String]) {
    Paths.ensureLogDir()
    ensureKey(replace: args.contains("--new-key"))
    var cfg = LoggerConfig.load()
    let profiles = loadChromeProfiles()
    if cfg.chromeMode(profiles: profiles) == .unset {
        if profiles.count <= 1 {
            // Nothing to tell apart with a single profile.
            cfg.chromeAllProfiles = true
            saveOrFail(cfg)
        } else if isatty(STDIN_FILENO) != 0 {
            say("\nWhich Chrome profile should be logged? The others are recorded without titles or URLs.")
            printProfiles(profiles)
            say("  a) every profile")
            for _ in 0..<3 {
                FileHandle.standardOutput.write(Data("Number (or a): ".utf8))
                guard let line = readLine() else { break }
                let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
                if answer == "a" {
                    cfg.chromeAllProfiles = true
                    saveOrFail(cfg)
                    break
                }
                if let n = Int(answer), n >= 1, n <= profiles.count {
                    applyProfile(profiles[n - 1], among: profiles)
                    break
                }
            }
        }
    }
    say("Chrome: " + describeChrome(LoggerConfig.load(), profiles))
    cmdMigrate()
    reportStrayFiles()
}

// MARK: - Files

struct DayFile {
    let day: String
    let url: URL
}

func dayFiles(in dir: URL, suffix: String) -> [DayFile] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(suffix) && $0.count == 10 + suffix.count }
        .sorted()
        .map { DayFile(day: String($0.prefix(10)), url: dir.appendingPathComponent($0)) }
}

/// Files in the log folder that this app didn't write, which may hold plain text.
func strayFiles() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.logDir.path)) ?? []
    let known = Set(dayFiles(in: Paths.logDir, suffix: Paths.encryptedSuffix).map { $0.url.lastPathComponent })
    return names.filter { !$0.hasPrefix(".") && !Paths.ownFiles.contains($0) && !known.contains($0) }.sorted()
}

func reportStrayFiles() {
    let stray = strayFiles()
    if stray.isEmpty { return }
    warn("Other files in the log folder that this app doesn't encrypt (check whether they hold old logs):")
    stray.forEach { warn("  \($0)") }
}

/// Appends one sealed row to a day's file, creating it (owner-only) if needed. `day` is the
/// file's YYYY-MM-DD, which the row is bound to.
func appendEncryptedRow(_ row: Data, to file: URL, day: String, key: Curve25519.KeyAgreement.PublicKey) throws {
    var line = try LogCrypto.encryptLine(row, day: day, to: key)
    line.append(0x0A)
    let fm = FileManager.default
    if !fm.fileExists(atPath: file.path) {
        fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    let handle = try FileHandle(forUpdating: file)
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    if end > 0 {
        // If the last write was cut short (a crash, a full disk), start on a fresh line so this row survives.
        try handle.seek(toOffset: end - 1)
        if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
        try handle.seekToEnd()
    }
    try handle.write(contentsOf: line)
}

/// Decrypts every row of the given files. Returns plain JSONL and the number of unreadable rows.
func decryptFiles(_ files: [DayFile], key: Curve25519.KeyAgreement.PrivateKey) -> (Data, Int) {
    var out = Data()
    var bad = 0
    for f in files {
        guard let data = try? Data(contentsOf: f.url) else { continue }
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let row = try? LogCrypto.decryptLine(Data(line), day: f.day, with: key) {
                out.append(row)
                out.append(0x0A)
            } else {
                bad += 1
            }
        }
    }
    return (out, bad)
}

// MARK: - Export

func cmdExport(_ args: [String]) {
    var days = 7
    var from: String?
    var to: String?
    var all = false
    var copy = false
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("\(args[i - 1]) needs a value.") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--days":
            guard let n = Int(value()), n >= 1 else { fail("--days needs a whole number, like --days 7.") }
            days = n
        case "--from": from = value()
        case "--to": to = value()
        case "--all": all = true
        case "--copy": copy = true
        default: fail("Unknown option \(args[i]).\n\n\(usage)")
        }
        i += 1
    }
    let today = dayFormatter.string(from: Date())
    if !all && from == nil {
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date()
        from = dayFormatter.string(from: start)
    }
    let files = dayFiles(in: Paths.logDir, suffix: Paths.encryptedSuffix).filter {
        (from == nil || $0.day >= from!) && $0.day <= (to ?? today)
    }
    if files.isEmpty { fail("No logs in that range in \(Paths.logDir.path).") }

    guard let vault = KeyVault.load() else {
        fail("key.json is missing or damaged, so the logs can't be decrypted. Run `activity-logger status`.")
    }
    let key: Curve25519.KeyAgreement.PrivateKey
    do {
        key = try vault.unlock(reason: "decrypt your activity logs from \(files.first!.day) to \(files.last!.day)")
    } catch {
        fail("Not decrypted: \(error.localizedDescription)")
    }
    if LoggerConfig.load().publicKey != vault.publicKey {
        warn("Warning: config.json names a different encryption key than key.json, so recent rows may be unreadable. Run `activity-logger setup` to restore it.")
    }

    let (data, bad) = decryptFiles(files, key: key)
    if bad > 0 { warn("\(bad) row(s) couldn't be decrypted and were skipped.") }
    if copy {
        copyBriefly(String(decoding: data, as: UTF8.self),
                    summary: "\(data.split(separator: 0x0A).count) rows (\(files.first!.day) to \(files.last!.day))")
    } else {
        FileHandle.standardOutput.write(data)
    }
}

/// Puts text on the clipboard for two minutes. It is marked so clipboard managers don't keep
/// it and it isn't shared with your other Apple devices, then cleared unless you copied
/// something else in the meantime.
func copyBriefly(_ text: String, summary: String) {
    let pb = NSPasteboard.general
    pb.prepareForNewContents(with: .currentHostOnly)
    pb.setString(text, forType: .string)
    pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    let mine = pb.changeCount
    say("Copied \(summary). Paste into Claude now. The clipboard is cleared in 2 minutes (Ctrl-C keeps it).")
    for _ in 0..<120 {
        Thread.sleep(forTimeInterval: 1)
        if pb.changeCount != mine { return }
    }
    pb.clearContents()
    say("Clipboard cleared.")
}

// MARK: - Migrate

/// Encrypts any plain-text day files left by the original logger, then deletes them.
func cmdMigrate() {
    let plain = dayFiles(in: Paths.logDir, suffix: Paths.plainSuffix)
    if plain.isEmpty { return }
    guard let b64 = LoggerConfig.load().publicKey, let key = LogCrypto.publicKey(base64: b64) else {
        fail("No encryption key yet. Run `activity-logger setup` first.")
    }
    for f in plain {
        guard let data = try? Data(contentsOf: f.url) else { continue }
        let target = Paths.logDir.appendingPathComponent(f.day + Paths.encryptedSuffix)
        do {
            // Appended row by row, so a logger that is running at the same time loses nothing.
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                try appendEncryptedRow(Data(line), to: target, day: f.day, key: key)
            }
            try FileManager.default.removeItem(at: f.url)
        } catch {
            fail("Couldn't encrypt \(f.url.lastPathComponent): \(error). It was left as it is.")
        }
    }
    say("Encrypted \(plain.count) plain-text log file(s) and removed the originals. Copies in Time Machine or other backups are not touched.")
}

// MARK: - Status

func cmdStatus() {
    let cfg = LoggerConfig.load()
    say("Log folder: \(Paths.logDir.path)")
    let pub = cfg.publicKey.flatMap { LogCrypto.publicKey(base64: $0) }
    let vault = KeyVault.load()
    var keyLine = "on (reading logs back needs Touch ID or your password)"
    if pub == nil {
        keyLine = "NOT SET UP, so nothing is being logged. Run `activity-logger setup`."
    } else if vault == nil {
        keyLine = "on, but key.json is missing or damaged, so logs can't be read back."
    } else if vault!.publicKey != cfg.publicKey {
        keyLine = "WARNING: config.json names a different key than key.json, so new rows can't be read back. Run `activity-logger setup` to restore it."
    }
    say("Encryption: \(keyLine)")
    say("Chrome: " + describeChrome(cfg, loadChromeProfiles()))
    let enc = dayFiles(in: Paths.logDir, suffix: Paths.encryptedSuffix)
    say("Encrypted days: \(enc.count)" + (enc.isEmpty ? "" : " (\(enc.first!.day) to \(enc.last!.day))"))
    let plain = dayFiles(in: Paths.logDir, suffix: Paths.plainSuffix)
    if !plain.isEmpty { say("Plain-text days still on disk: \(plain.count). Run `activity-logger setup` to encrypt them.") }
    reportStrayFiles()
    let errors = Paths.logDir.appendingPathComponent("errors.log")
    if let text = try? String(contentsOf: errors, encoding: .utf8) {
        let lines = text.split(separator: "\n").suffix(8)
        if !lines.isEmpty {
            say("Recent notes from the logger:")
            lines.forEach { say("  \($0)") }
        }
    }
}

// MARK: - Self-test

func cmdSelfTest() {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        say((ok ? "ok    " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    // Window title parsing
    check(chromeProfileLabel(fromWindowTitle: "Inbox - Google Chrome - Work") == "Work", "label after the page title")
    check(chromeProfileLabel(fromWindowTitle: "Inbox - Google Chrome") == "", "no label with a single profile")
    check(chromeProfileLabel(fromWindowTitle: "Inbox") == nil, "no marker gives nil")
    check(chromeProfileLabel(fromWindowTitle: "x - Google Chrome - Work - Google Chrome - Home") == "Home",
          "a page can't fake a label in its title")
    check(chromeProfileLabel(fromWindowTitle: "a - b - Google Chrome - Ana (work.org)") == "Ana (work.org)", "label with brackets")
    check(chromeProfileLabel(fromWindowTitle: "x - Google Chromecast help") == nil, "marker must be followed by a label")

    // Labels that tell profiles apart
    let home = ChromeProfile(directory: "Profile 1", name: "Andrés", givenName: "Andrés", fullName: "Andrés C",
                             email: "a@example.com", enterpriseLabel: "")
    let work = ChromeProfile(directory: "Profile 2", name: "work.org", givenName: "Andres", fullName: "Andres C",
                             email: "a@work.org", enterpriseLabel: "")
    let twin = ChromeProfile(directory: "Profile 3", name: "Andrés", givenName: "", fullName: "", email: "", enterpriseLabel: "")
    var cfg = LoggerConfig()
    check(cfg.chromeMode(profiles: [home, work]) == .unset, "no choice means Chrome is withheld, not logged")
    cfg.chromeProfileDirectory = "Profile 2"
    if case .profile(let l) = cfg.chromeMode(profiles: [home, work]) {
        check(l.contains("Andres (work.org)"), "labels come from the chosen profile")
    } else { check(false, "labels come from the chosen profile") }
    let rival = ChromeProfile(directory: "Profile 9", name: "work.org", givenName: "Andres", fullName: "", email: "", enterpriseLabel: "")
    if case .profile(let l) = cfg.chromeMode(profiles: [home, work, rival]) {
        check(!l.contains("work.org") && !l.contains("Andres (work.org)"), "a profile added later can't inherit a label")
    } else { check(false, "a profile added later can't inherit a label") }
    cfg.chromeProfileDirectory = "Profile 404"
    check(cfg.chromeMode(profiles: [home, work]) == .profile(labels: []), "a deleted profile leaves nothing allowed")
    cfg.chromeAllProfiles = true
    check(cfg.chromeMode(profiles: [home, work]) == .all, "every-profile mode")
    let w = uniqueLabels(for: work, among: [home, work])
    check(w.contains("Andres (work.org)") && w.contains("work.org") && w.contains("Andres"), "work profile labels")
    check(!w.contains("Andrés"), "accented and unaccented names stay distinct")
    check(!uniqueLabels(for: home, among: [home, twin]).contains("Andrés"), "a label shared with another profile is dropped")

    // Row encryption
    do {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let other = Curve25519.KeyAgreement.PrivateKey()
        let row = Data(#"{"app":"Notes","window_title":"Café ☕ list"}"#.utf8)
        let day = "2026-01-01"
        let line = try LogCrypto.encryptLine(row, day: day, to: priv.publicKey)
        check(!String(decoding: line, as: UTF8.self).contains("Notes"), "sealed row has no plain text")
        check(try LogCrypto.decryptLine(line, day: day, with: priv) == row, "row decrypts with the right key")
        check((try? LogCrypto.decryptLine(line, day: day, with: other)) == nil, "row doesn't decrypt with another key")
        check((try? LogCrypto.decryptLine(line, day: "2026-01-02", with: priv)) == nil, "row can't be moved to another day")
        var raw = Data(base64Encoded: line)!
        raw[raw.count - 1] ^= 1
        check((try? LogCrypto.decryptLine(raw.base64EncodedData(), day: day, with: priv)) == nil, "tampered row is rejected")
        check(try LogCrypto.encryptLine(row, day: day, to: priv.publicKey) != line, "the same row never encrypts to the same bytes")
        let long = Data(#"{"window_title":"a much longer title than the other one, by a fair margin"}"#.utf8)
        check(try LogCrypto.encryptLine(long, day: day, to: priv.publicKey).count == line.count, "rows are padded to the same size")

        // Files
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("al-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f1 = dir.appendingPathComponent("2026-01-01" + Paths.encryptedSuffix)
        let f2 = dir.appendingPathComponent("2026-01-02" + Paths.encryptedSuffix)
        try appendEncryptedRow(Data(#"{"n":1}"#.utf8), to: f1, day: "2026-01-01", key: priv.publicKey)
        let handle = try FileHandle(forWritingTo: f1)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("cut-short-row".utf8))   // a write that never finished
        try handle.close()
        try appendEncryptedRow(Data(#"{"n":2}"#.utf8), to: f1, day: "2026-01-01", key: priv.publicKey)
        try appendEncryptedRow(Data(#"{"n":3}"#.utf8), to: f2, day: "2026-01-02", key: priv.publicKey)
        try Data("not a row\n".utf8).write(to: dir.appendingPathComponent("errors.log"))
        let files = dayFiles(in: dir, suffix: Paths.encryptedSuffix)
        check(files.map(\.day) == ["2026-01-01", "2026-01-02"], "day files are found in order")
        let (plain, bad) = decryptFiles(files, key: priv)
        check(String(decoding: plain, as: UTF8.self) == "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n" && bad == 1,
              "files decrypt back to JSONL, and a cut-short row costs only itself")
        let perms = (try FileManager.default.attributesOfItem(atPath: f1.path)[.posixPermissions] as? NSNumber)?.intValue
        check(perms == 0o600, "log files are readable by the owner only")
        check(decryptFiles(files, key: other).0.isEmpty, "another key reads nothing")

        // Key wrapping in the Secure Enclave (without the Touch ID rule, so the test can run unattended)
        let vault = try KeyVault.create(requirePresence: false)
        let vaultFile = dir.appendingPathComponent("key.json")
        try vault.save(to: vaultFile)
        guard let loaded = KeyVault.load(from: vaultFile) else { throw LogCrypto.Malformed() }
        check(!String(decoding: try Data(contentsOf: vaultFile), as: UTF8.self).isEmpty && loaded.publicKey == vault.publicKey, "key.json round trip")
        let unlocked = try loaded.unlock(reason: "self-test")
        let sealed = try LogCrypto.encryptLine(row, day: day, to: LogCrypto.publicKey(base64: loaded.publicKey)!)
        check(try LogCrypto.decryptLine(sealed, day: day, with: unlocked) == row, "the unwrapped key reads rows sealed to its public half")
        var broken = loaded
        var wrapped = Data(base64Encoded: broken.wrappedPrivateKey)!
        wrapped[wrapped.count - 1] ^= 1
        broken.wrappedPrivateKey = wrapped.base64EncodedString()
        check((try? broken.unlock(reason: "self-test")) == nil, "a tampered wrapped key is rejected")
    } catch {
        check(false, "encryption threw: \(error)")
    }

    say(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}
