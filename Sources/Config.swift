import Foundation

// Where things live, the config file, and how a Chrome window is matched to a profile.

enum Paths {
    /// Log folder. ACTIVITY_LOGGER_DIR overrides it (used by tests).
    static let logDir: URL = {
        if let o = ProcessInfo.processInfo.environment["ACTIVITY_LOGGER_DIR"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("personal-tools/data/activity-logger", isDirectory: true)
    }()
    static var configFile: URL { logDir.appendingPathComponent("config.json") }
    static let encryptedSuffix = ".jsonl.enc"
    static let plainSuffix = ".jsonl"
    /// Files the app itself keeps in the log folder besides the day files.
    static let ownFiles: Set<String> = ["config.json", "key.json", "errors.log"]

    /// Creates the log folder, readable by this user only.
    static func ensureLogDir() {
        let fm = FileManager.default
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logDir.path)
    }
}

/// What the logger records for Chrome windows.
enum ChromeMode: Equatable {
    /// No choice made yet: Chrome is recorded without titles or URLs.
    case unset
    /// Every profile is logged (Incognito windows still aren't).
    case all
    /// Only windows carrying one of these profile labels are logged.
    case profile(labels: [String])
}

struct LoggerConfig: Codable, Equatable {
    /// Base64 X25519 public key the logger encrypts to. The private half is wrapped in key.json.
    var publicKey: String?
    /// True logs every Chrome profile.
    var chromeAllProfiles: Bool?
    /// Chrome's folder name for the one profile that is logged, such as "Profile 3".
    var chromeProfileDirectory: String?
    /// That profile's name, for display only.
    var chromeProfile: String?
    /// Extra window labels to accept, set by hand with `set-profile --label`.
    var chromeExtraLabels: [String]?

    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case chromeAllProfiles = "chrome_all_profiles"
        case chromeProfileDirectory = "chrome_profile_directory"
        case chromeProfile = "chrome_profile"
        case chromeExtraLabels = "chrome_extra_labels"
    }

    /// The labels are worked out from Chrome's current profile list every time, so a profile
    /// added or renamed later can't inherit a label that was unique when the choice was made.
    func chromeMode(profiles: [ChromeProfile]) -> ChromeMode {
        if chromeAllProfiles == true { return .all }
        var labels = chromeExtraLabels ?? []
        if let dir = chromeProfileDirectory, let p = profiles.first(where: { $0.directory == dir }) {
            for l in uniqueLabels(for: p, among: profiles) where !labels.contains(l) { labels.append(l) }
        }
        if chromeProfileDirectory == nil && labels.isEmpty { return .unset }
        return .profile(labels: labels)
    }

    static func load() -> LoggerConfig {
        guard let data = try? Data(contentsOf: Paths.configFile),
              let cfg = try? JSONDecoder().decode(LoggerConfig.self, from: data) else { return LoggerConfig() }
        return cfg
    }

    func save() throws {
        Paths.ensureLogDir()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: Paths.configFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.configFile.path)
    }
}

// MARK: - Chrome profiles

struct ChromeProfile {
    let directory: String      // "Profile 3"
    let name: String           // the name you gave the profile in Chrome
    let givenName: String
    let fullName: String
    let email: String
    let enterpriseLabel: String

    var domain: String { email.split(separator: "@").last.map(String.init) ?? "" }

    var shortName: String { name.isEmpty ? directory : name }

    var display: String {
        var s = shortName
        if !email.isEmpty { s += " (\(email))" }
        return s
    }

    /// Every label Chrome might show for this profile at the end of a window title. Chrome
    /// picks one of these depending on its version and on whether the profile is signed in.
    var candidateLabels: [String] {
        var out: [String] = []
        func add(_ s: String) { if !s.isEmpty && !out.contains(s) { out.append(s) } }
        add(name); add(givenName); add(fullName)
        if !name.isEmpty {
            if !givenName.isEmpty { add("\(givenName) (\(name))") }
            if !fullName.isEmpty { add("\(fullName) (\(name))") }
        }
        add(email); add(enterpriseLabel)
        return out
    }
}

let chromeLocalState = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")

func loadChromeProfiles() -> [ChromeProfile] {
    let url = chromeLocalState
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let profile = root["profile"] as? [String: Any],
          let cache = profile["info_cache"] as? [String: Any] else { return [] }
    return cache.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { dir in
        guard let e = cache[dir] as? [String: Any] else { return nil }
        func s(_ k: String) -> String { (e[k] as? String) ?? "" }
        return ChromeProfile(directory: dir, name: s("name"), givenName: s("gaia_given_name"),
                             fullName: s("gaia_name"), email: s("user_name"), enterpriseLabel: s("enterprise_label"))
    }
}

/// The profile's candidate labels, minus any that another profile could also show.
func uniqueLabels(for p: ChromeProfile, among all: [ChromeProfile]) -> [String] {
    let others = Set(all.filter { $0.directory != p.directory }.flatMap { $0.candidateLabels })
    return p.candidateLabels.filter { !others.contains($0) }
}

/// The profile label at the end of a Chrome window title, as read through Accessibility:
/// "Page - Google Chrome - Work" gives "Work", "Page - Google Chrome" gives "" (Chrome only
/// adds a label when there is more than one profile), and anything else gives nil. Chrome
/// appends its own part after the page title, so the last marker is always Chrome's and a
/// page cannot fake a label by putting one in its title.
func chromeProfileLabel(fromWindowTitle title: String) -> String? {
    let marker = " - Google Chrome"
    guard let r = title.range(of: marker, options: .backwards) else { return nil }
    let rest = title[r.upperBound...]
    if rest.isEmpty { return "" }
    guard rest.hasPrefix(" - ") else { return nil }
    return String(rest.dropFirst(3))
}

func collapseWhitespace(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}
