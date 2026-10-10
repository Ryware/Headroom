import Foundation
import SwiftUI

enum ScanPhase: Equatable {
    case idle, scanning, done, failed(String)
}

struct ScanProgress {
    var files = 0
    var directories = 0
    var bytes: Int64 = 0
    var errors = 0
    var current = ""
    var started = Date()
    var finished: Date?
    var elapsed: TimeInterval { (finished ?? Date()).timeIntervalSince(started) }
}

struct DuplicateProgress: Equatable {
    var done = 0
    var total = 0
    var bytes: Int64 = 0
    var current = ""
    var phase = ""
    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

struct DeleteProgress: Equatable {
    var done = 0
    var total = 0
    var bytes: Int64 = 0
    var current = ""
    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

@MainActor
final class AppState: ObservableObject {
    @Published var root: FileNode?
    @Published var rootURL: URL?
    /// What `rootURL` is, named for people ("Macintosh HD", not "/").
    @Published private(set) var rootLocation: ScanLocation?
    @Published var phase: ScanPhase = .idle
    @Published var progress = ScanProgress()
    @Published var selection: Set<FileNode.ID> = [] {
        didSet {
            // Inspector follows the most recently added selected item.
            if let id = selection.subtracting(oldValue).first ?? selection.first, let n = index[id] {
                selectedNode = n
            }
        }
    }
    @Published var selectedNode: FileNode?
    @Published var deleteMode: DeleteMode = .trash
    @Published var deleting: DeleteProgress?
    private var deleteControl: Deleter.DeleteControl?
    @Published var lastDeleteResult: DeleteResult?
    @Published var cleanupCandidates: [CleanupCandidate] = []
    @Published var knownLocationCandidates: [CleanupCandidate] = []
    @Published var scanningKnownLocations = false
    @Published var categoryTotals: [FileCategory: Int64] = [:]
    @Published var largest: [FileNode] = []
    @Published var treeVersion = 0
    @Published var duplicates: DuplicateScanResult?
    @Published var duplicateProgress: DuplicateProgress?
    private var duplicateTask: Task<Void, Never>?
    /// Installed by the outline view so deletions animate rows out instead of reloading.
    var treeRemovalHandler: (([FileNode]) -> Bool)?
    @Published var recentScans: [URL] = []

    private static let recentScanPathsKey = "recentScans"
    private static let recentScanBookmarksKey = "recentScanBookmarks"
    private var scanTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var counters = ScanCounters()
#if APP_STORE
    private var securityScopedURL: URL?
    private var isAccessingSecurityScopedURL = false
#endif

    /// Map from id to node for selection lookups.
    private var index: [FileNode.ID: FileNode] = [:]

    init() {
        recentScans = Self.loadRecentScans()
    }

    private static func loadRecentScans() -> [URL] {
#if APP_STORE
        let bookmarks = UserDefaults.standard.array(forKey: recentScanBookmarksKey) as? [Data] ?? []
        return bookmarks.compactMap { data in
            var isStale = false
            return try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
#else
        return (UserDefaults.standard.stringArray(forKey: recentScanPathsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
#endif
    }

    private func rememberRecentScan(_ url: URL) {
        recentScans.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentScans.insert(url, at: 0)
        recentScans = Array(recentScans.prefix(5))

#if APP_STORE
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        let existing = UserDefaults.standard.array(forKey: Self.recentScanBookmarksKey) as? [Data] ?? []
        let filtered = existing.filter { data in
            var isStale = false
            guard let savedURL = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return false }
            return savedURL.standardizedFileURL != url.standardizedFileURL
        }
        UserDefaults.standard.set(Array(([bookmark] + filtered).prefix(5)), forKey: Self.recentScanBookmarksKey)
#else
        UserDefaults.standard.set(recentScans.map(\.path), forKey: Self.recentScanPathsKey)
#endif
    }

#if APP_STORE
    private func activateSecurityScope(for url: URL) {
        guard securityScopedURL?.standardizedFileURL != url.standardizedFileURL else { return }
        if isAccessingSecurityScopedURL {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = url
        isAccessingSecurityScopedURL = url.startAccessingSecurityScopedResource()
    }
#endif

    var isScanning: Bool { phase == .scanning }

    // MARK: Scanning

    func scan(_ url: URL) {
        cancelScan()
#if APP_STORE
        activateSecurityScope(for: url)
#endif
        rootURL = url
        rootLocation = ScanLocation(url: url)
        rememberRecentScan(url)
        root = nil
        selection = []
        selectedNode = nil
        cleanupCandidates = []
        categoryTotals = [:]
        largest = []
        index = [:]
        cancelDuplicateScan()
        duplicates = nil
        counters = ScanCounters()
        progress = ScanProgress()
        phase = .scanning

        let counters = self.counters
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pullCounters() }
        }

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let scanner = DiskScanner(counters: counters, options: ScanOptions())
            do {
                let node = try await scanner.scan(root: url)
                await self?.finishScan(node)
            } catch is CancellationError {
                await self?.setPhase(.idle)
            } catch {
                await self?.setPhase(.failed(error.localizedDescription))
            }
        }
    }

    func rescan() {
        if let rootURL { scan(rootURL) }
    }

    /// Waits for the running scan, if any, and returns the tree it produced (nil if it was cancelled or failed).
    func waitForScan() async -> FileNode? {
        await scanTask?.value
        return phase == .done ? root : nil
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func setPhase(_ p: ScanPhase) { phase = p }
    private func setKnownLocations(_ c: [CleanupCandidate]) {
        knownLocationCandidates = c
        scanningKnownLocations = false
    }

    private func pullCounters() {
        let s = counters.snapshot
        progress.files = s.files
        progress.directories = s.directories
        progress.bytes = s.bytes
        progress.errors = s.errors
        progress.current = s.current
    }

    private func finishScan(_ node: FileNode) {
        pollTimer?.invalidate()
        pollTimer = nil
        pullCounters()
        progress.finished = Date()
        root = node
        selectedNode = node
        phase = .done
        treeVersion += 1
        rebuildDerived()
    }

    func rebuildDerived() {
        guard let root else { return }
        var idx: [FileNode.ID: FileNode] = [:]
        root.walk { idx[$0.id] = $0 }
        index = idx
        categoryTotals = root.categoryTotals()
        largest = root.largestItems(limit: 100)
        cleanupCandidates = CleanupFinder.candidates(in: root)
    }

    func node(for id: FileNode.ID) -> FileNode? { index[id] }

    var selectedNodes: [FileNode] {
        selection.compactMap { index[$0] }
    }

    // MARK: Known junk locations (independent of the open folder)

    func scanKnownLocations() {
#if APP_STORE
        // App Store builds only inspect the folder explicitly selected by the user.
        knownLocationCandidates = []
        scanningKnownLocations = false
#else
        guard !scanningKnownLocations else { return }
        scanningKnownLocations = true
        knownLocationCandidates = []
        Task.detached(priority: .utility) { [weak self] in
            var found: [CleanupCandidate] = []
            let scanner = DiskScanner(counters: ScanCounters(), options: ScanOptions())
            for loc in CleanupFinder.knownLocations {
                if let node = try? await scanner.scan(root: URL(fileURLWithPath: loc.path)), node.allocatedSize > 0 {
                    found.append(CleanupCandidate(kind: loc.kind, node: node, contentsOnly: true))
                }
            }
            let sorted = found.sorted { $0.size > $1.size }
            await self?.setKnownLocations(sorted)
        }
#endif
    }

    // MARK: Duplicates

    func findDuplicates() {
        guard let root, duplicateProgress == nil else { return }
        let counters = DuplicateCounters()
        duplicateProgress = DuplicateProgress()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            let s = counters.snapshot
            Task { @MainActor in
                guard self?.duplicateProgress != nil else { return }
                let next = DuplicateProgress(done: s.done, total: s.total, bytes: s.bytes, current: s.current, phase: s.phase)
                // Publishing an unchanged value still re-renders every view observing AppState.
                if self?.duplicateProgress != next { self?.duplicateProgress = next }
            }
        }
        duplicateTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = try? await DuplicateFinder(counters: counters).find(in: root)
            await MainActor.run { [weak self] in
                timer.invalidate()
                guard let self else { return }
                self.duplicateProgress = nil
                if let result { self.duplicates = result }
            }
        }
    }

    /// Starts a duplicate search (or joins the running one) and returns its result once done.
    func findDuplicatesAndWait() async -> DuplicateScanResult? {
        if duplicateProgress == nil { findDuplicates() }
        await duplicateTask?.value
        return duplicates
    }

    func cancelDuplicateScan() {
        duplicateTask?.cancel()
        duplicateTask = nil
        duplicateProgress = nil
    }

    /// Drop deleted files from the duplicate groups without rehashing anything.
    private func pruneDuplicates(removed: [FileNode]) {
        guard var d = duplicates, !removed.isEmpty else { return }
        let gone = Set(removed.map(\.id))
        d.groups = d.groups.compactMap { g in
            let left = g.files.filter { !gone.contains($0.id) }
            return left.count > 1 ? DuplicateGroup(id: g.id, size: g.size, files: left) : nil
        }
        duplicates = d
    }

    // MARK: Deleting

    @discardableResult
    func delete(_ nodes: [FileNode], mode: DeleteMode? = nil, silent: Bool = false) async -> DeleteResult? {
        guard !nodes.isEmpty, deleting == nil else { return nil }
        let counters = DeleteCounters()
        let control = Deleter.DeleteControl()
        deleteControl = control
        deleting = DeleteProgress()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            let s = counters.snapshot
            Task { @MainActor in
                guard self?.deleting != nil else { return }
                let next = DeleteProgress(done: s.done, total: s.total, bytes: s.bytes, current: s.current)
                // Publishing an unchanged value still re-renders every view observing AppState
                // (the whole window, ten times a second, for as long as the delete runs).
                if self?.deleting != next { self?.deleting = next }
            }
        }
        let deleter = Deleter(mode: mode ?? deleteMode, counters: counters, control: control)
        let result = await Task.detached(priority: .userInitiated) { await deleter.delete(nodes) }.value
        timer.invalidate()
        deleteControl = nil

        // Drop removed nodes from the in-memory tree instead of rescanning.
        let removed = nodes.filter { n in !result.errors.contains(where: { $0.path.hasPrefix(n.path) }) }
        for n in removed {
            selection.remove(n.id)
            if selectedNode === n { selectedNode = n.parent }
        }
        if !(treeRemovalHandler?(removed) ?? false) {
            for n in removed { n.parent?.removeChild(n) }
            treeVersion += 1
        }
        knownLocationCandidates.removeAll { c in nodes.contains { $0 === c.node } }
        pruneDuplicates(removed: removed)
        deleting = nil
        rebuildDerived()
        if let root {
            progress.files = root.fileCount
            progress.directories = root.directoryCount
            progress.bytes = root.allocatedSize
        }
        // Let the progress sheet finish dismissing before presenting the summary alert.
        if !silent {
            try? await Task.sleep(for: .milliseconds(350))
            lastDeleteResult = result
        }
        return result
    }

    /// Stops a running permanent delete after the unlinks already in flight return.
    func cancelDelete() { deleteControl?.cancel() }

    // MARK: Folder picking

    func pickFolder(startingAt directoryURL: URL? = nil) {
        let panel = NSOpenPanel()
        panel.directoryURL = directoryURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            scan(url)
        }
    }

    func revealInFinder(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }
}
