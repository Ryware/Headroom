import Foundation

/// How to name a scanned root for people, the way Finder does. A bare "/" means nothing to
/// someone who isn't used to Unix paths: volumes go by their volume name ("Macintosh HD"),
/// folders by their Finder display name, and the home folder gets the house icon.
struct ScanLocation: Equatable {
    enum Kind: Equatable { case startupDisk, volume, home, folder }

    let kind: Kind
    /// Headline as Finder shows it: "Macintosh HD", "ilya" (home), "Downloads".
    let name: String
    let path: String

    var symbol: String {
        switch kind {
        case .startupDisk: return "internaldrive"
        case .volume: return "externaldrive"
        case .home: return "house"
        case .folder: return "folder"
        }
    }

    var isVolume: Bool { kind == .startupDisk || kind == .volume }

    /// Second line under the name; the path itself when it says more than the name does.
    var detail: String {
        switch kind {
        case .startupDisk: return "Whole startup disk"
        case .volume: return "Whole volume · \(path)"
        case .home: return path
        case .folder: return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// One line for headers: the path for folders, the name for disks and home.
    var summary: String { kind == .folder ? detail : "\(name) · \(detail)" }

    /// "Find duplicate files on Macintosh HD" but "in Downloads".
    var phrase: String { (isVolume ? "on " : "in ") + name }

    init(kind: Kind, name: String, path: String) {
        self.kind = kind
        self.name = name
        self.path = path
    }

    /// Pure classification, so it can be tested without real volumes.
    /// `displayName` is Finder's name for a folder (localized, e.g. "Загрузки" for Downloads);
    /// falls back to the last path component.
    init(path: String, isVolumeRoot: Bool, volumeName: String?, displayName: String? = nil,
         homePath: String = NSHomeDirectory()) {
        let path = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if path == "/" {
            self.init(kind: .startupDisk, name: volumeName ?? "Startup Disk", path: path)
        } else if isVolumeRoot {
            self.init(kind: .volume, name: volumeName ?? (path as NSString).lastPathComponent, path: path)
        } else {
            let last = (path as NSString).lastPathComponent
            let name = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? (last.isEmpty ? path : last)
            self.init(kind: path == homePath ? .home : .folder, name: name, path: path)
        }
    }

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeLocalizedNameKey, .volumeNameKey])
        let path = url.standardizedFileURL.path
        self.init(path: path, isVolumeRoot: values?.isVolume ?? false,
                  volumeName: values?.volumeLocalizedName ?? values?.volumeName,
                  displayName: FileManager.default.displayName(atPath: path))
    }
}
