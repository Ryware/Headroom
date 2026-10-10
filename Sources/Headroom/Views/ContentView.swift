import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case dashboard, tree, treemap, categories, largest, duplicates, cleanup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .tree: return "Folder Tree"
        case .treemap: return "Treemap"
        case .categories: return "By Category"
        case .largest: return "Largest Files"
        case .duplicates: return "Duplicates"
        case .cleanup: return "Cleanup"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "chart.bar.xaxis"
        case .tree: return "folder"
        case .treemap: return "square.grid.3x3.square"
        case .categories: return "chart.pie"
        case .largest: return "arrow.up.doc"
        case .duplicates: return "doc.on.doc"
        case .cleanup: return "sparkles"
        }
    }
}

/// Back/Forward through the panes, like Finder: ⌘[ and ⌘], the toolbar arrows, and ⌘← / ⌘→
/// outside text fields. A stop remembers the By Category selection so Back restores it.
final class Navigation: ObservableObject {
    struct Stop: Equatable {
        var pane: Pane
        var category: FileCategory?
    }

    @Published private(set) var current = Stop(pane: .dashboard)
    @Published private(set) var back: [Stop] = []
    @Published private(set) var forward: [Stop] = []
    /// Category to open By Category with, set when the Dashboard links to one.
    var categoryFocus: FileCategory?

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func go(_ pane: Pane) {
        let category = pane == .categories ? categoryFocus : nil
        categoryFocus = nil
        guard pane != current.pane else { return }
        back.append(current)
        forward = []
        current = Stop(pane: pane, category: category)
    }

    func goBack() {
        guard let stop = back.popLast() else { return }
        forward.append(current)
        current = stop
    }

    func goForward() {
        guard let stop = forward.popLast() else { return }
        back.append(current)
        current = stop
    }

    /// By Category reports its selection so Back comes back to it; not a history step.
    func noteCategory(_ category: FileCategory?) {
        if current.pane == .categories { current.category = category }
    }

    func reset() {
        back = []
        forward = []
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var nav = Navigation()
    @State private var keyMonitor: Any?
    @AppStorage("seenBackTip") private var seenBackTip = false
    @State private var showBackTip = false
    private var pane: Pane { nav.current.pane }
    @State private var showInspector = false
    @State private var pendingDelete: [FileNode] = []
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                ZStack { detail }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                // Duplicates has its own selection (ticked copies); the global one would be stale there.
                StatusBar(showsSelection: pane != .duplicates)
            }
            .frame(minWidth: 520, minHeight: 420)
            .task {
                // Present the inspector after the first layout pass; presenting it during the
                // initial constraint update can trip AppKit's split-view min-size race.
                try? await Task.sleep(for: .milliseconds(300))
                showInspector = true
            }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 240, ideal: 290, max: 400)
            }
        }
        .toolbar { toolbar }
        .focusedSceneObject(nav)
        .onChange(of: state.rootURL) { _, _ in nav.reset() }
        .onAppear(perform: installArrowKeys)
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        .sheet(isPresented: Binding(get: { state.deleting != nil }, set: { _ in })) {
            DeleteProgressSheet()
        }
        .alert("Delete \(pendingDelete.count) item\(pendingDelete.count == 1 ? "" : "s")?", isPresented: $showDeleteConfirm) {
            Button(state.deleteMode == .trash ? "Move to Trash" : "Delete Permanently", role: .destructive) {
                let items = pendingDelete
                pendingDelete = []
                Task { await state.delete(items) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text(confirmMessage(for: pendingDelete, mode: state.deleteMode))
        }
        .overlay(alignment: .bottom) {
            if let r = state.lastDeleteResult {
                DeleteToast(result: r, mode: state.deleteMode) {
                    withAnimation(.spring(duration: 0.4)) { state.lastDeleteResult = nil }
                }
                .padding(.bottom, 44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.25), value: state.lastDeleteResult?.freedBytes)
        .overlay(alignment: .bottom) {
            if showBackTip && state.lastDeleteResult == nil {
                BackTip().padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environment(\.requestDelete, RequestDeleteAction { nodes in
            guard !nodes.isEmpty else { return }
            pendingDelete = nodes
            showDeleteConfirm = true
        })
    }

    private var sidebar: some View {
        List(selection: Binding<Pane?>(get: { pane }, set: { if let p = $0 { nav.go(p) } })) {
            ForEach(Pane.allCases) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            if let root = state.root, let location = state.rootLocation {
                Spacer().frame(height: 8)
                Section("Scanned") {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(location.name, systemImage: location.symbol).font(.headline).lineLimit(1)
                        Text(location.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                            .help(location.path)
                        Text("\(root.allocatedSize.humanBytes) · \(root.fileCount.formatted()) files")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }

    @ViewBuilder
    private var detail: some View {
        if state.isScanning && state.root == nil {
            ScanningView()
        } else if state.root == nil && pane != .cleanup {
            WelcomeView()
        } else {
            switch pane {
            case .dashboard:
                DashboardView(pane: Binding(get: { nav.current.pane }, set: { nav.go($0); offerBackTip() }),
                              categoryFocus: Binding(get: { nav.categoryFocus }, set: { nav.categoryFocus = $0 }))
            case .tree: TreeView()
            case .treemap: TreemapView()
            case .categories: CategoriesView(initial: nav.current.category, onSelect: nav.noteCategory)
            case .largest: LargestFilesView()
            case .duplicates: DuplicatesView()
            case .cleanup: CleanupView()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { nav.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!nav.canGoBack)
                    .help("Back (⌘[)")
                Button { nav.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!nav.canGoForward)
                    .help("Forward (⌘])")
            }
            .controlGroupStyle(.navigation)
            Button { state.pickFolder() } label: { Label("Scan Folder", systemImage: "folder.badge.plus") }
                .help("Choose a folder or volume to scan (⌘O)")
            Button { state.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(state.rootURL == nil || state.isScanning)
                .help("Rescan (⌘R)")
            if state.isScanning {
                Button { state.cancelScan(); state.phase = .idle } label: { Label("Stop", systemImage: "stop.circle") }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Delete mode", selection: $state.deleteMode) {
                ForEach(DeleteMode.allCases) { Text($0 == .trash ? "Trash" : "Permanent").tag($0) }
            }
            .pickerStyle(.segmented)
            .help(state.deleteMode.shortNote)
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show what the selected item is and whether it's safe to delete")
        }
    }
}

extension ContentView {
    /// The first time the Dashboard sends someone to another view, say once how to come back.
    private func offerBackTip() {
        guard !seenBackTip, nav.canGoBack else { return }
        seenBackTip = true
        withAnimation(.spring(duration: 0.4)) { showBackTip = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            withAnimation(.easeOut(duration: 0.3)) { showBackTip = false }
        }
    }

    /// ⌘← / ⌘→ go Back / Forward as in Safari, except while typing, where they move the caret.
    private func installArrowKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [nav] event in
            // Arrow keys also carry .function and .numericPad, so compare only the real modifiers.
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  let window = event.window, window.canBecomeMain, window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return event }
            switch event.keyCode {
            case 123 where nav.canGoBack: nav.goBack(); return nil      // ←
            case 124 where nav.canGoForward: nav.goForward(); return nil // →
            default: return event
            }
        }
    }
}

private struct BackTip: View {
    var body: some View {
        Label {
            Text("Tip: press **⌘[** or **‹** in the toolbar to go back, and **⌘1** for the Dashboard.")
        } icon: {
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(Color.accentColor)
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

/// The Go menu: Back, Forward and ⌘1… for each pane.
struct GoCommands: Commands {
    @FocusedObject private var nav: Navigation?

    var body: some Commands {
        CommandMenu("Go") {
            Button("Back") { nav?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(nav?.canGoBack ?? false))
            Button("Forward") { nav?.goForward() }
                .keyboardShortcut("]")
                .disabled(!(nav?.canGoForward ?? false))
            Divider()
            ForEach(Array(Pane.allCases.enumerated()), id: \.element) { i, pane in
                Button(pane.title) { nav?.go(pane) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
                    .disabled(nav == nil)
            }
        }
    }
}

/// Injected action so any subview can ask for a confirmed delete.
struct RequestDeleteAction {
    let run: ([FileNode]) -> Void
    func callAsFunction(_ nodes: [FileNode]) { run(nodes) }
}

private struct RequestDeleteKey: EnvironmentKey {
    static let defaultValue = RequestDeleteAction { _ in }
}

extension EnvironmentValues {
    var requestDelete: RequestDeleteAction {
        get { self[RequestDeleteKey.self] }
        set { self[RequestDeleteKey.self] = newValue }
    }
}

struct DeleteSummary: Identifiable {
    let id = UUID()
    let freed: String
    let detail: String
    init(_ r: DeleteResult) {
        freed = r.freedBytes.humanBytes
        var d = "\(r.removedFiles.formatted()) files, \(r.removedDirectories.formatted()) folders removed."
        if !r.errors.isEmpty {
            d += "\n\(r.errors.count) item(s) could not be removed:\n" + r.errors.prefix(5).map { "• \($0.path): \($0.message)" }.joined(separator: "\n")
        }
        detail = d
    }
}

struct StatusBar: View {
    @EnvironmentObject var state: AppState
    var showsSelection = true
    var body: some View {
        HStack(spacing: 12) {
            switch state.phase {
            case .idle:
                Text("Ready").foregroundStyle(.secondary)
            case .scanning:
                ProgressView().controlSize(.small)
                Text("\(state.progress.files.formatted()) files · \(state.progress.directories.formatted()) folders · \(state.progress.bytes.humanBytes)")
                Text(state.progress.current).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            case .done:
                Text("\(state.progress.files.formatted()) files · \(state.progress.directories.formatted()) folders · \(state.progress.bytes.humanBytes) in \(String(format: "%.1fs", state.progress.elapsed))")
                if state.progress.errors > 0 {
                    Text("· \(state.progress.errors) unreadable").foregroundStyle(.orange)
                }
            case .failed(let msg):
                Text("Scan failed: \(msg)").foregroundStyle(.red)
            }
            Spacer()
            if showsSelection && !state.selection.isEmpty {
                let total = state.selectedNodes.reduce(0) { $0 + $1.allocatedSize }
                Text("\(state.selection.count) selected · \(total.humanBytes)").foregroundStyle(.secondary)
            }
            Label(state.deleteMode == .trash ? "Trash mode" : "Permanent mode", systemImage: state.deleteMode.symbol)
                .foregroundStyle(state.deleteMode == .permanent ? .red : .secondary)
                .help(state.deleteMode.shortNote)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// What the delete confirmation says. Mentions an installed security product up front when the
/// items sit in a folder it guards, so a stop a moment later is not a mystery.
private func confirmMessage(for nodes: [FileNode], mode: DeleteMode) -> String {
    let total = nodes.reduce(0) { $0 + $1.allocatedSize }
    var text = mode == .trash
        ? "\(total.humanBytes) will be moved to the Trash."
        : "\(total.humanBytes) will be removed permanently. This cannot be undone."
    let suspects = SecuritySuites.suspects
    if !suspects.isEmpty, nodes.contains(where: { SecuritySuites.isGuarded($0.path) }) {
        text += "\n\n" + SecuritySuites.warning(for: suspects)
    }
    return text
}

struct DeleteProgressSheet: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 14) {
            let p = state.deleting ?? DeleteProgress()
            Text(state.deleteMode == .trash ? "Moving to Trash…" : "Deleting…").font(.headline)
            ProgressView(value: p.fraction)
            Text("\(p.done.formatted()) / \(p.total.formatted()) · \(p.bytes.humanBytes) freed")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            if !p.current.isEmpty {
                Text(p.current).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity)
            }
            if state.deleteMode == .permanent {
                Button("Cancel") { state.cancelDelete() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
