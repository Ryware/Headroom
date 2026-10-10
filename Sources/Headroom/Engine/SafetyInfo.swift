import Foundation
import SwiftUI

/// How safe it is to delete something.
enum SafetyLevel: Int, Comparable, CaseIterable {
    case safe = 0        // regenerated automatically, no data loss
    case usuallySafe     // regenerable, but costs a re-download / rebuild / re-login
    case caution         // user data or app state — check before deleting
    case never           // OS / app integrity; deleting breaks things
    case unknown

    static func < (l: SafetyLevel, r: SafetyLevel) -> Bool { l.rawValue < r.rawValue }

    var title: String {
        switch self {
        case .safe: return "Safe to delete"
        case .usuallySafe: return "Usually safe"
        case .caution: return "Check first"
        case .never: return "Do not delete"
        case .unknown: return "Unknown"
        }
    }
    var symbol: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .usuallySafe: return "shield.lefthalf.filled"
        case .caution: return "exclamationmark.triangle.fill"
        case .never: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    /// Muted, desaturated palette: reads as a quiet status, not a neon alert.
    var color: Color {
        switch self {
        case .safe: return Color(red: 0.38, green: 0.78, blue: 0.54)        // fresh green, not neon
        case .usuallySafe: return Color(red: 0.42, green: 0.76, blue: 0.80) // aqua
        case .caution: return Color(red: 0.96, green: 0.70, blue: 0.34)     // warm amber
        case .never: return Color(red: 0.93, green: 0.42, blue: 0.42)       // soft red
        case .unknown: return .secondary
        }
    }
    var short: String {
        switch self {
        case .safe: return "Safe"
        case .usuallySafe: return "Usually safe"
        case .caution: return "Caution"
        case .never: return "Never"
        case .unknown: return "—"
        }
    }
}

struct SafetyInfo {
    let level: SafetyLevel
    let what: String        // what this folder / file is
    let advice: String      // what happens if you delete it
    var source: String = "" // which rule matched (for the inspector)

    static let unknown = SafetyInfo(level: .unknown, what: "No information about this item.",
                                    advice: "Look at what's inside and where it lives before deleting.")
}

/// Rule-based knowledge base: exact home-relative paths first, then absolute prefixes,
/// then folder names anywhere, then file extensions.
enum SafetyKB {
    private struct Rule {
        let level: SafetyLevel
        let what: String
        let advice: String
    }

    // MARK: Home-relative paths (most specific)
    private static let homePaths: [String: Rule] = [
        "Library": .init(level: .caution, what: "Your user Library: app data, caches, preferences, mail, keychains.", advice: "Never delete the folder itself. Clean only the Caches, Logs and Developer subfolders, or data of apps you removed."),
        "Library/Caches": .init(level: .safe, what: "Per-app caches (browsers, App Store, Xcode, Homebrew…).", advice: "Apps rebuild them. First launch after cleaning may be a bit slower. Quit apps first to avoid partial rebuilds."),
        "Library/Caches/Homebrew": .init(level: .safe, what: "Downloaded bottles and source tarballs kept by Homebrew.", advice: "`brew cleanup` deletes the same thing. Re-downloaded on the next install."),
        "Library/Caches/pip": .init(level: .safe, what: "pip download/wheel cache.", advice: "Re-downloaded on the next pip install."),
        "Library/Developer/Xcode/DerivedData": .init(level: .safe, what: "Xcode build products, indexes and module caches for every project you've opened.", advice: "Regenerated on the next build. Deleting it also fixes many 'weird' Xcode errors."),
        "Library/Developer/Xcode/Archives": .init(level: .caution, what: "App archives (.xcarchive) you built for distribution — include dSYMs needed to symbolicate crashes.", advice: "Keep archives of versions still in the wild; older ones can go."),
        "Library/Developer/Xcode/iOS DeviceSupport": .init(level: .usuallySafe, what: "Debug symbols for every iOS version you've ever plugged in.", advice: "Xcode re-downloads the ones it needs from the next device you connect. Old iOS versions are pure waste."),
        "Library/Developer/Xcode/watchOS DeviceSupport": .init(level: .usuallySafe, what: "Debug symbols for watchOS versions.", advice: "Re-downloaded when needed."),
        "Library/Developer/Xcode/UserData/Previews": .init(level: .safe, what: "SwiftUI preview simulators and caches.", advice: "Regenerated automatically."),
        "Library/Developer/CoreSimulator/Devices": .init(level: .caution, what: "iOS/watchOS simulator devices with their installed apps and data.", advice: "Use `xcrun simctl delete unavailable` to drop devices for runtimes you no longer have. Deleting everything wipes simulator app data."),
        "Library/Developer/CoreSimulator/Caches": .init(level: .safe, what: "Simulator dyld caches.", advice: "Regenerated on next simulator boot."),
        "Library/Developer/Xcode/UserData": .init(level: .caution, what: "Xcode breakpoints, snippets, key bindings, themes.", advice: "Only the Previews subfolder is cache; the rest is your customization."),
        "Library/Logs": .init(level: .safe, what: "Application and diagnostic logs.", advice: "Useful only when debugging a problem. Safe to clear."),
        "Library/Logs/DiagnosticReports": .init(level: .safe, what: "Crash and hang reports.", advice: "Delete unless you need to send one to a developer."),
        "Library/Application Support": .init(level: .caution, what: "Per-app data: settings, databases, extensions, local project state.", advice: "Deleting an app's folder here resets that app. Only remove folders of apps you have uninstalled."),
        "Library/Containers": .init(level: .caution, what: "Sandboxed app data (each folder is an app's private home).", advice: "Deleting a container wipes that app's data. Folders for uninstalled apps can go. Docker's data lives here too."),
        "Library/Group Containers": .init(level: .caution, what: "Data shared between an app and its extensions.", advice: "Same rules as Containers."),
        "Library/Mail": .init(level: .never, what: "Apple Mail's local mailboxes and index.", advice: "Deleting loses local mail. Manage from Mail.app."),
        "Library/Messages": .init(level: .never, what: "iMessage history and attachments.", advice: "Manage from Messages settings, not here."),
        "Library/Mobile Documents": .init(level: .never, what: "iCloud Drive local copies.", advice: "Deleting here deletes from iCloud on all devices."),
        "Library/CloudStorage": .init(level: .never, what: "Cloud providers' synced folders (Dropbox, OneDrive, Google Drive).", advice: "Deleting here deletes in the cloud. Use the provider's 'free up space' option instead."),
        "Library/Keychains": .init(level: .never, what: "Your passwords and certificates.", advice: "Never touch."),
        "Library/Preferences": .init(level: .never, what: "Settings for every app (.plist).", advice: "Tiny anyway; deleting resets apps."),
        "Library/Metadata": .init(level: .safe, what: "Spotlight and CoreSpotlight indexes.", advice: "Rebuilt automatically; expect a re-index."),
        "Library/Saved Application State": .init(level: .safe, what: "Window positions and 'reopen windows on relaunch' state.", advice: "Harmless to clear."),
        "Library/Autosave Information": .init(level: .caution, what: "Unsaved document recovery data.", advice: "Only delete if nothing is open."),
        ".Trash": .init(level: .safe, what: "Files you already deleted in Finder.", advice: "Emptying the Trash frees the space for real."),
        ".cache": .init(level: .safe, what: "XDG cache used by CLI tools (Hugging Face, pre-commit, pip, uv…).", advice: "Tools re-download what they need. Large model downloads live in .cache/huggingface — those take a while to fetch again."),
        ".cache/huggingface": .init(level: .usuallySafe, what: "Downloaded Hugging Face models and datasets.", advice: "Re-downloaded on next use; can be many GB per model."),
        ".npm": .init(level: .safe, what: "npm's package cache (_cacache).", advice: "`npm cache clean --force` does the same. Re-downloaded on the next install."),
        ".npm/_cacache": .init(level: .safe, what: "npm's content-addressed tarball cache.", advice: "Safe; re-downloaded on next install."),
        ".pnpm-store": .init(level: .usuallySafe, what: "pnpm's global content store — projects hard-link into it.", advice: "Deleting it breaks node_modules of pnpm projects until you run `pnpm install` again. Prefer `pnpm store prune`."),
        ".yarn/cache": .init(level: .safe, what: "Yarn's global package cache.", advice: "Re-downloaded on next install."),
        ".gradle/caches": .init(level: .safe, what: "Gradle's dependency and build caches.", advice: "Re-downloaded / rebuilt on the next Gradle build."),
        ".gradle/wrapper": .init(level: .safe, what: "Downloaded Gradle distributions.", advice: "Re-downloaded by the wrapper on next build."),
        ".m2/repository": .init(level: .safe, what: "Maven's local artifact repository.", advice: "Re-downloaded on next build. Locally installed (mvn install) snapshots are lost."),
        ".nuget/packages": .init(level: .safe, what: "NuGet global packages folder.", advice: "Restored on the next `dotnet restore`."),
        ".cargo/registry": .init(level: .safe, what: "Downloaded Rust crates and index.", advice: "Re-downloaded on next cargo build."),
        ".cargo/git": .init(level: .safe, what: "Git-sourced Rust dependencies.", advice: "Re-fetched on next build."),
        ".rustup/toolchains": .init(level: .usuallySafe, what: "Installed Rust toolchains.", advice: "Use `rustup toolchain uninstall` for old versions."),
        ".cocoapods/repos": .init(level: .safe, what: "CocoaPods spec repositories (git clones).", advice: "Re-cloned on next `pod install --repo-update`."),
        ".ollama": .init(level: .usuallySafe, what: "Ollama's downloaded LLM models (models/blobs).", advice: "Use `ollama rm <model>` for individual models; each is a multi-GB re-download."),
        ".lmstudio": .init(level: .usuallySafe, what: "LM Studio models.", advice: "Delete from inside LM Studio to keep its index consistent."),
        ".docker": .init(level: .caution, what: "Docker CLI config and contexts (small); images are in Library/Containers/com.docker.docker.", advice: "Use `docker system prune` to reclaim image space instead."),
        "Library/Containers/com.docker.docker": .init(level: .caution, what: "Docker Desktop's Linux VM disk (Docker.raw) holding all images, containers and volumes.", advice: "Don't delete the file — run `docker system prune -a --volumes` and shrink the disk in Docker Desktop settings."),
        ".android": .init(level: .usuallySafe, what: "Android emulator AVDs and adb keys.", advice: "AVDs can be recreated in Android Studio; adbkey removal makes devices re-prompt for authorization."),
        ".conda": .init(level: .usuallySafe, what: "Conda environments and package cache.", advice: "`conda clean --all` for the cache; environments are recreatable from environment.yml."),
        ".vscode/extensions": .init(level: .usuallySafe, what: "Installed VS Code extensions.", advice: "Reinstallable; deleting resets your extension set."),
        ".cursor/extensions": .init(level: .usuallySafe, what: "Installed Cursor extensions.", advice: "Reinstallable."),
        ".ssh": .init(level: .never, what: "SSH keys and known hosts.", advice: "Never delete."),
        ".gnupg": .init(level: .never, what: "GPG keys.", advice: "Never delete."),
        ".config": .init(level: .caution, what: "Configuration for CLI tools and some apps.", advice: "Small; deleting resets tools."),
        ".local/share": .init(level: .caution, what: "XDG data for CLI tools (shell histories, virtualenvs, pipx, uv tools).", advice: "Check each subfolder."),
        ".zsh_sessions": .init(level: .safe, what: "Terminal session restore data.", advice: "Harmless."),
        "Downloads": .init(level: .caution, what: "Your downloads.", advice: "Usually the best place to reclaim space by hand — installers (.dmg/.pkg) can go once the app is installed."),
        "Movies/TV": .init(level: .caution, what: "Apple TV app downloads.", advice: "Remove downloads from inside the TV app."),
        "Music/Music": .init(level: .caution, what: "Apple Music library and downloads.", advice: "Manage from Music.app."),
        "Pictures/Photos Library.photoslibrary": .init(level: .never, what: "Your Photos library.", advice: "Manage inside Photos; enable 'Optimize Mac Storage' to free space."),
        "Virtual Machines.localized": .init(level: .caution, what: "Parallels virtual machines.", advice: "Each .pvm is a whole VM. Delete from Parallels Control Center."),
    ]

    // MARK: Absolute prefixes
    private static let absolutePrefixes: [(String, Rule)] = [
        ("/System", .init(level: .never, what: "macOS itself (sealed system volume).", advice: "Read-only and protected; nothing to reclaim here.")),
        ("/usr", .init(level: .never, what: "System binaries and libraries.", advice: "Protected by SIP. Homebrew lives in /usr/local or /opt/homebrew.")),
        ("/bin", .init(level: .never, what: "Core system commands.", advice: "Protected.")),
        ("/sbin", .init(level: .never, what: "Core system commands.", advice: "Protected.")),
        ("/private/var/db", .init(level: .never, what: "System databases (Spotlight, dyld caches, receipts).", advice: "Do not touch.")),
        ("/private/var/vm", .init(level: .never, what: "Swap and sleepimage.", advice: "Managed by the kernel.")),
        ("/private/var/folders", .init(level: .usuallySafe, what: "Per-user temporary files and caches (TMPDIR, Caches for CLI tools).", advice: "macOS cleans these periodically; reboot clears most. Deleting while apps run can break them.")),
        ("/private/tmp", .init(level: .safe, what: "Temporary files.", advice: "Cleared on reboot anyway.")),
        ("/Library/Caches", .init(level: .safe, what: "System-wide caches.", advice: "Rebuilt automatically.")),
        ("/Library/Logs", .init(level: .safe, what: "System-wide logs.", advice: "Safe to clear.")),
        ("/Library/Developer/CommandLineTools", .init(level: .caution, what: "Xcode Command Line Tools.", advice: "Needed by Homebrew, git and compilers. Reinstall with `xcode-select --install`.")),
        ("/Library/Application Support", .init(level: .caution, what: "System-wide app data (Adobe, Microsoft, drivers).", advice: "Uninstalled apps often leave GBs here; check names against installed apps.")),
        ("/Library/Extensions", .init(level: .caution, what: "Third-party kernel extensions / drivers.", advice: "Only remove drivers for hardware you no longer own; use the vendor's uninstaller.")),
        ("/Library/Printers", .init(level: .usuallySafe, what: "Printer drivers.", advice: "macOS re-downloads drivers for printers you add; drivers for printers you no longer have are dead weight.")),
        ("/Applications", .init(level: .caution, what: "Installed applications.", advice: "Drag to Trash to uninstall; check the app's own uninstaller for helper files.")),
        ("/opt/homebrew", .init(level: .caution, what: "Homebrew installation (Apple silicon).", advice: "Use `brew uninstall` / `brew cleanup`, not manual deletion.")),
        ("/usr/local", .init(level: .caution, what: "Homebrew (Intel) and manually installed software.", advice: "Use the installer's uninstall path.")),
    ]

    // MARK: Folder names anywhere
    private static let folderNames: [String: Rule] = [
        "node_modules": .init(level: .safe, what: "Installed npm/yarn/pnpm dependencies for one project.", advice: "`npm install` recreates it exactly from package-lock.json. Delete for projects you're not working on."),
        ".venv": .init(level: .safe, what: "Python virtual environment.", advice: "Recreate with `python -m venv .venv && pip install -r requirements.txt` (or uv/poetry)."),
        "venv": .init(level: .safe, what: "Python virtual environment.", advice: "Recreatable from requirements."),
        "__pycache__": .init(level: .safe, what: "Compiled Python bytecode.", advice: "Regenerated on next run."),
        ".pytest_cache": .init(level: .safe, what: "pytest cache.", advice: "Regenerated."),
        ".mypy_cache": .init(level: .safe, what: "mypy type-check cache.", advice: "Regenerated."),
        ".ruff_cache": .init(level: .safe, what: "ruff lint cache.", advice: "Regenerated."),
        "Pods": .init(level: .safe, what: "CocoaPods dependencies for one Xcode project.", advice: "`pod install` recreates it from Podfile.lock."),
        ".build": .init(level: .safe, what: "Swift Package Manager build output.", advice: "`swift build` regenerates it."),
        "DerivedData": .init(level: .safe, what: "Xcode build output.", advice: "Regenerated on the next build."),
        "target": .init(level: .safe, what: "Rust (Cargo) or Maven build output.", advice: "`cargo build` / `mvn package` regenerates it. Rust targets are often multi-GB."),
        "build": .init(level: .usuallySafe, what: "Build output (Gradle, CMake, Android, Python…).", advice: "Regenerated by the next build — as long as this is really a build folder and not source."),
        "dist": .init(level: .usuallySafe, what: "Bundled / packaged output of a build.", advice: "Regenerated by the build script."),
        ".next": .init(level: .safe, what: "Next.js build cache and output.", advice: "Regenerated by `next build` / `next dev`."),
        ".nuxt": .init(level: .safe, what: "Nuxt build output.", advice: "Regenerated."),
        ".turbo": .init(level: .safe, what: "Turborepo cache.", advice: "Regenerated."),
        ".parcel-cache": .init(level: .safe, what: "Parcel bundler cache.", advice: "Regenerated."),
        ".angular": .init(level: .safe, what: "Angular CLI cache.", advice: "Regenerated."),
        ".gradle": .init(level: .safe, what: "Gradle project cache.", advice: "Regenerated on next build."),
        ".idea": .init(level: .caution, what: "JetBrains IDE project settings (run configs, code style).", advice: "Small; deleting resets IDE settings for the project."),
        ".vscode": .init(level: .caution, what: "VS Code workspace settings.", advice: "Small; contains launch/tasks configs."),
        "bin": .init(level: .usuallySafe, what: ".NET build output (next to obj/).", advice: "Regenerated by `dotnet build`."),
        "obj": .init(level: .safe, what: ".NET intermediate build output.", advice: "Regenerated by `dotnet build`."),
        "vendor": .init(level: .usuallySafe, what: "Vendored dependencies (Go, PHP Composer, Ruby).", advice: "Recreated by the package manager; sometimes committed to git — check."),
        "bower_components": .init(level: .safe, what: "Legacy Bower dependencies.", advice: "Recreatable; project probably long dead."),
        ".pnpm-store": .init(level: .usuallySafe, what: "pnpm content store (projects hard-link into it).", advice: "Run `pnpm install` afterwards in projects that used it; prefer `pnpm store prune`."),
        ".pnpm": .init(level: .safe, what: "pnpm's virtual store inside node_modules.", advice: "Recreated by `pnpm install`."),
        ".dart_tool": .init(level: .safe, what: "Dart/Flutter build cache.", advice: "Regenerated by `flutter pub get`."),
        ".serverless": .init(level: .safe, what: "Serverless Framework packaging output.", advice: "Regenerated on deploy."),
        "coverage": .init(level: .safe, what: "Test coverage reports.", advice: "Regenerated by the test run."),
        ".ipynb_checkpoints": .init(level: .safe, what: "Jupyter notebook autosave checkpoints.", advice: "Regenerated while editing."),
        "Photos Library.photoslibrary": .init(level: .never, what: "Your Photos library.", advice: "Manage inside Photos."),
        ".terraform": .init(level: .safe, what: "Downloaded Terraform providers and modules.", advice: "`terraform init` recreates it. Do NOT delete terraform.tfstate next to it."),
        ".git": .init(level: .never, what: "Git repository history.", advice: "Deleting loses all history and unpushed commits. Run `git gc` to shrink."),
        "Caches": .init(level: .safe, what: "Cache folder.", advice: "Rebuilt by its owner app."),
        ".cache": .init(level: .safe, what: "Cache folder used by CLI tools.", advice: "Re-downloaded / rebuilt on next use."),
        "cache": .init(level: .safe, what: "Cache folder.", advice: "Rebuilt by its owner."),
        "Cache": .init(level: .safe, what: "Cache folder.", advice: "Rebuilt by its owner."),
        "CachedData": .init(level: .safe, what: "Electron/VS Code cached data.", advice: "Rebuilt."),
        "Code Cache": .init(level: .safe, what: "Chromium code cache.", advice: "Rebuilt."),
        "GPUCache": .init(level: .safe, what: "Chromium GPU shader cache.", advice: "Rebuilt."),
        "Service Worker": .init(level: .safe, what: "Chromium service-worker cache.", advice: "Rebuilt by websites on next visit."),
        "tmp": .init(level: .safe, what: "Temporary files.", advice: "Safe when the owning process isn't running."),
        "temp": .init(level: .safe, what: "Temporary files.", advice: "Safe when the owning process isn't running."),
        "Logs": .init(level: .safe, what: "Log files.", advice: "Safe."),
        "logs": .init(level: .safe, what: "Log files.", advice: "Safe."),
        "DiagnosticReports": .init(level: .safe, what: "Crash reports.", advice: "Safe."),
        "Backups": .init(level: .caution, what: "Backups.", advice: "Make sure you have a newer copy before deleting."),
        "Backup": .init(level: .caution, what: "Backups (iOS device backups live in Library/Application Support/MobileSync/Backup).", advice: "Old device backups can be many GB; delete from Finder's device page or after confirming you don't need them."),
        "MobileSync": .init(level: .caution, what: "iPhone/iPad backups made by Finder/iTunes.", advice: "Each backup is a full device image. Remove old devices from Finder > device > Manage Backups."),
        "site-packages": .init(level: .usuallySafe, what: "Installed Python packages of one interpreter/venv.", advice: "Reinstall with pip. If this is the system Python, leave it."),
        "blobs": .init(level: .usuallySafe, what: "Content-addressed blobs (OCI images, Ollama models).", advice: "Delete via the owning tool (docker/ollama) so its index stays valid."),
    ]

    // MARK: File extensions
    private static let extensions: [String: Rule] = [
        "dmg": .init(level: .usuallySafe, what: "Disk image, usually an app installer.", advice: "Delete once the app is installed."),
        "pkg": .init(level: .usuallySafe, what: "Installer package.", advice: "Delete once installed."),
        "iso": .init(level: .usuallySafe, what: "Disc image.", advice: "Re-downloadable; delete if you don't need the installer."),
        "xcarchive": .init(level: .caution, what: "Xcode archive with dSYMs.", advice: "Keep for versions still in production."),
        "ipa": .init(level: .usuallySafe, what: "iOS app package.", advice: "Rebuildable."),
        "log": .init(level: .safe, what: "Log file.", advice: "Safe."),
        "crash": .init(level: .safe, what: "Crash report.", advice: "Safe."),
        "ips": .init(level: .safe, what: "Crash/diagnostic report.", advice: "Safe."),
        "tmp": .init(level: .safe, what: "Temporary file.", advice: "Safe if no app is using it."),
        "part": .init(level: .safe, what: "Incomplete download.", advice: "Safe."),
        "crdownload": .init(level: .safe, what: "Incomplete Chrome download.", advice: "Safe."),
        "download": .init(level: .safe, what: "Incomplete Safari download.", advice: "Safe."),
        "gguf": .init(level: .usuallySafe, what: "LLM model weights.", advice: "Re-downloadable, but large."),
        "safetensors": .init(level: .usuallySafe, what: "Model weights.", advice: "Re-downloadable, but large."),
        "raw": .init(level: .caution, what: "Raw disk image (Docker Desktop's VM disk if named Docker.raw).", advice: "Manage from Docker Desktop; deleting loses all images/containers/volumes."),
        "vmdk": .init(level: .caution, what: "Virtual machine disk.", advice: "Deleting destroys the VM's contents."),
        "qcow2": .init(level: .caution, what: "Virtual machine disk.", advice: "Deleting destroys the VM's contents."),
        "sparseimage": .init(level: .caution, what: "Expandable disk image (often a Time Machine or encrypted volume).", advice: "Check contents before deleting."),
        "sparsebundle": .init(level: .caution, what: "Bundle disk image (Time Machine network backups).", advice: "Check contents before deleting."),
        "vscdb": .init(level: .caution, what: "VS Code / Cursor workspace state database (chat history, undo, etc.).", advice: "Deleting resets that workspace's state."),
        "sqlite": .init(level: .caution, what: "SQLite database used by an app.", advice: "App data; don't delete while the app runs."),
        "db": .init(level: .caution, what: "Database file.", advice: "App data."),
        "zip": .init(level: .usuallySafe, what: "Archive.", advice: "Delete if already extracted."),
        "tar": .init(level: .usuallySafe, what: "Archive.", advice: "Delete if already extracted."),
        "gz": .init(level: .usuallySafe, what: "Compressed archive.", advice: "Delete if already extracted."),
    ]

    // MARK: Lookup

    private static let homePrefix = NSHomeDirectory() + "/"
    private static let absoluteIndex = Dictionary(absolutePrefixes, uniquingKeysWith: { first, _ in first })
    private static let bundleRule = Rule(level: .caution, what: "Application or bundle.",
                                         advice: "Uninstall through the app's own uninstaller or by dragging to Trash if you no longer use it.")

    /// Which rule matched. Kept as parts so `level(for:)` never builds strings.
    private enum Source {
        case home(String), prefix(String), folder(String), ext(String), bundle
        var text: String {
            switch self {
            case .home(let rel): return "~/" + rel
            case .prefix(let p): return p
            case .folder(let name): return name + "/"
            case .ext(let ext): return "." + ext
            case .bundle: return "bundle"
            }
        }
    }

    static func info(for node: FileNode) -> SafetyInfo {
        guard let m = match(node) else { return .unknown }
        let source = m.source.text
        if m.inherited {
            return SafetyInfo(level: m.rule.level, what: "Inside " + source + " — " + m.rule.what, advice: m.rule.advice, source: source)
        }
        return SafetyInfo(level: m.rule.level, what: m.rule.what, advice: m.rule.advice, source: source)
    }

    /// Just the level: what colour-coding needs, without the explanatory strings.
    static func level(for node: FileNode) -> SafetyLevel {
        match(node)?.rule.level ?? .unknown
    }

    private static func match(_ node: FileNode) -> (rule: Rule, source: Source, inherited: Bool)? {
        if let m = directMatch(node, asAncestor: false) { return (m.rule, m.source, false) }
        // Inherit from the nearest known ancestor: a file deep inside ~/Library/Caches is
        // safe; inside Application Support it stays 'caution'.
        var p = node.parent
        while let anc = p {
            if let m = directMatch(anc, asAncestor: true) { return (m.rule, m.source, true) }
            p = anc.parent
        }
        return nil
    }

    /// Rules in order: exact home-relative path, exact absolute path, folder name, then
    /// (for files and bundles only, not when walking up) file extension.
    private static func directMatch(_ node: FileNode, asAncestor: Bool) -> (rule: Rule, source: Source)? {
        let path = node.path
        if path.hasPrefix(homePrefix) {
            let rel = String(path.dropFirst(homePrefix.count))
            if let r = homePaths[rel] { return (r, .home(rel)) }
        }
        if let r = absoluteIndex[path] { return (r, .prefix(path)) }
        if asAncestor || node.isDirectory, let r = folderNames[node.name] { return (r, .folder(node.name)) }
        guard !asAncestor, !node.isDirectory || node.isPackage else { return nil }
        let ext = (node.name as NSString).pathExtension.lowercased()
        if let r = extensions[ext] { return (r, .ext(ext)) }
        if node.isPackage { return (bundleRule, .bundle) }
        return nil
    }
}
