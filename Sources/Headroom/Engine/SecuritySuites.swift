import Foundation
import AppKit

/// A third-party security product that may guard user folders (Documents, Desktop, Downloads,
/// Pictures) and hold or refuse file changes from apps it does not know. Its Endpoint Security
/// client decides every unlink and rename in those folders; a refused one comes back as EPERM
/// after seconds, which looks exactly like a permission problem. Headroom cannot and should not
/// get around that. What it can do is name the product and say where to allow Headroom.
struct SecuritySuite: Identifiable, Equatable {
    let id: String
    let name: String
    /// The folder-guard feature, when the product is known to have one ("Safe Files").
    let feature: String?
    /// Where to allow Headroom, as a path through the product's own UI.
    let howToAllow: String
    /// App bundles: used both to detect the product and to open it for the user.
    let appPaths: [String]
    /// Other files or folders that prove the product is installed.
    let markerPaths: [String]

    var guardsFolders: Bool { feature != nil }
    var appURL: URL? {
        appPaths.map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static let known: [SecuritySuite] = [
        SecuritySuite(id: "avg", name: "AVG Antivirus", feature: "Ransomware Shield",
                      howToAllow: "AVG › Menu › Settings › General › Blocked & Allowed Apps › Allow app › Headroom",
                      appPaths: ["/Applications/AVGAntivirus.app"],
                      markerPaths: ["/Library/Application Support/AVGAntivirus"]),
        SecuritySuite(id: "avast", name: "Avast Security", feature: "Ransomware Shield",
                      howToAllow: "Avast › Menu › Settings › General › Blocked & Allowed Apps › Allow app › Headroom",
                      appPaths: ["/Applications/Avast.app", "/Applications/Avast Security.app", "/Applications/Avast One.app"],
                      markerPaths: ["/Library/Application Support/Avast"]),
        SecuritySuite(id: "bitdefender", name: "Bitdefender", feature: "Safe Files",
                      howToAllow: "Bitdefender › Protection › Anti-Ransomware › Safe Files › Manage Applications › set Headroom to Allowed",
                      appPaths: ["/Applications/Bitdefender/AntivirusforMac.app", "/Applications/Bitdefender/CoreSecurity.app",
                                 "/Applications/Bitdefender Antivirus for Mac.app", "/Applications/Bitdefender Virus Scanner.app"],
                      markerPaths: ["/Library/Bitdefender", "/Applications/Bitdefender"]),
        SecuritySuite(id: "trendmicro", name: "Trend Micro Antivirus", feature: "Folder Shield",
                      howToAllow: "Trend Micro › Folder Shield › Trusted Program List › add Headroom",
                      appPaths: ["/Applications/Trend Micro Antivirus.app"],
                      markerPaths: ["/Library/Application Support/TrendMicro"]),
        SecuritySuite(id: "norton", name: "Norton", feature: nil,
                      howToAllow: "Norton › Settings › allow Headroom in its file protection",
                      appPaths: ["/Applications/Norton 360.app", "/Applications/Norton Security.app", "/Applications/Norton.app"],
                      markerPaths: ["/Library/Application Support/Norton"]),
        SecuritySuite(id: "mcafee", name: "McAfee", feature: nil,
                      howToAllow: "McAfee › Settings › allow Headroom in its file protection",
                      appPaths: ["/Applications/McAfee Total Protection.app", "/Applications/McAfee Endpoint Security for Mac.app"],
                      markerPaths: ["/Library/McAfee"]),
        SecuritySuite(id: "kaspersky", name: "Kaspersky", feature: nil,
                      howToAllow: "Kaspersky › Settings › Threats and Exclusions › trusted applications › add Headroom",
                      appPaths: ["/Applications/Kaspersky.app", "/Applications/Kaspersky Internet Security.app", "/Applications/Kaspersky Premium.app"],
                      markerPaths: ["/Library/Application Support/Kaspersky Lab"]),
        SecuritySuite(id: "eset", name: "ESET", feature: nil,
                      howToAllow: "ESET › Setup › Exclusions › add Headroom",
                      appPaths: ["/Applications/ESET Cyber Security.app", "/Applications/ESET Endpoint Security.app", "/Applications/ESET Endpoint Antivirus.app"],
                      markerPaths: ["/Library/Application Support/ESET"]),
        SecuritySuite(id: "sophos", name: "Sophos", feature: nil,
                      howToAllow: "Sophos Home › Protection › exclusions, or ask IT on a managed Mac",
                      appPaths: ["/Applications/Sophos/Sophos Endpoint.app", "/Applications/Sophos Home.app", "/Applications/Sophos Scan.app"],
                      markerPaths: ["/Library/Sophos Anti-Virus", "/Library/Application Support/Sophos"]),
        SecuritySuite(id: "malwarebytes", name: "Malwarebytes", feature: nil,
                      howToAllow: "Malwarebytes › Settings › Allow List › add Headroom",
                      appPaths: ["/Applications/Malwarebytes.app"],
                      markerPaths: ["/Library/Application Support/Malwarebytes"]),
        SecuritySuite(id: "defender", name: "Microsoft Defender", feature: nil,
                      howToAllow: "Managed by your organization: ask IT to allow Headroom",
                      appPaths: ["/Applications/Microsoft Defender.app"],
                      markerPaths: ["/Library/Application Support/Microsoft/Defender"]),
        SecuritySuite(id: "crowdstrike", name: "CrowdStrike Falcon", feature: nil,
                      howToAllow: "Managed by your organization: ask IT to allow Headroom",
                      appPaths: ["/Applications/Falcon.app"],
                      markerPaths: ["/Library/CS"]),
        SecuritySuite(id: "sentinelone", name: "SentinelOne", feature: nil,
                      howToAllow: "Managed by your organization: ask IT to allow Headroom",
                      appPaths: ["/Applications/SentinelOne/SentinelOne Extensions.app"],
                      markerPaths: ["/Library/Sentinel"]),
        SecuritySuite(id: "jamfprotect", name: "Jamf Protect", feature: nil,
                      howToAllow: "Managed by your organization: ask IT to allow Headroom",
                      appPaths: ["/Applications/JamfProtect.app"],
                      markerPaths: ["/Library/Application Support/JamfProtect"]),
    ]
}

enum SecuritySuites {
    /// Products found on this Mac. A handful of stat calls, done once per launch.
    static let installed: [SecuritySuite] = detect(fileExists: FileManager.default.fileExists(atPath:))

    static func detect(fileExists: (String) -> Bool) -> [SecuritySuite] {
        SecuritySuite.known.filter { s in (s.appPaths + s.markerPaths).contains(where: fileExists) }
    }

    /// The products that could be holding file operations: every one with a known folder guard,
    /// or all of them when none is known to have one. Two suites side by side is common, and
    /// the one the user already allowed is not the one refusing, so all are named.
    static var suspects: [SecuritySuite] { suspects(among: installed) }
    static func suspects(among suites: [SecuritySuite]) -> [SecuritySuite] {
        let guarding = suites.filter(\.guardsFolders)
        return guarding.isEmpty ? suites : guarding
    }

    /// "Bitdefender's Safe Files" / "AVG Antivirus's Ransomware Shield or Bitdefender's Safe Files".
    static func names(_ suites: [SecuritySuite]) -> String {
        suites.map { s in s.feature.map { "\(s.name)'s \($0)" } ?? s.name }.joined(separator: " or ")
    }
    private static func howToAllow(_ suites: [SecuritySuite]) -> String {
        suites.count == 1 ? "To allow it: \(suites[0].howToAllow)."
            : "To allow it: " + suites.map { "\($0.name): \($0.howToAllow)" }.joined(separator: "; ") + "."
    }

    /// Folders these products guard by default.
    static let guardedFolders: [String] = ["Documents", "Desktop", "Downloads", "Pictures"].map { NSHomeDirectory() + "/" + $0 }
    static func isGuarded(_ path: String) -> Bool { isGuarded(path, folders: guardedFolders) }
    static func isGuarded(_ path: String, folders: [String]) -> Bool {
        folders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Why a permanent delete stopped, naming the products when any is installed.
    static func stallMessage(for suites: [SecuritySuite]) -> String {
        let head = "Deleting stopped: every file removal was held for seconds and then refused. "
        let tail = " Or delete the item in Finder, which is always allowed."
        guard !suites.isEmpty else {
            return head + "An antivirus or ransomware shield (an Endpoint Security extension) is blocking Headroom in this folder. " +
                "Add Headroom to its allowed apps." + tail
        }
        return head + "\(names(suites)) is most likely blocking Headroom in this folder. \(howToAllow(suites))" + tail
    }

    /// Why a Trash move was refused inside a guarded folder.
    static func trashBlockedMessage(for suites: [SecuritySuite]) -> String {
        "macOS reports a permission problem, but this folder is guarded by \(names(suites)), which refuses apps it does not know. " +
            "\(howToAllow(suites)) Or delete the item in Finder, which is always allowed."
    }

    /// One line for the delete confirmation when the items sit in a guarded folder.
    static func warning(for suites: [SecuritySuite]) -> String {
        let allowIn = suites.map(\.name).joined(separator: " and ")
        return "\(names(suites)) guards this folder and may hold or refuse removals from apps it does not know. If this delete stops, allow Headroom in \(allowIn)."
    }
}
