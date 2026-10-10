import SwiftUI

/// Groups of byte-identical files. Pick which copies to remove; one copy per group always stays
/// unless the user explicitly unchecks that protection.
struct DuplicatesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.requestDelete) private var requestDelete
    @State private var checked: Set<FileNode.ID> = []
    @State private var expanded: Set<String> = []
    @State private var filter = ""
    @State private var keepOneCopy = true
    @State private var shown = 150
    /// Copies listed per group before "Show N more"; groups of hundreds of cache copies are noise.
    private let collapsedCopies = 5

    private var groups: [DuplicateGroup] {
        guard let d = state.duplicates else { return [] }
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return d.groups }
        return d.groups.filter { g in g.files.contains { $0.path.lowercased().contains(q) } }
    }
    private var checkedNodes: [FileNode] {
        groups.flatMap(\.files).filter { checked.contains($0.id) }
    }
    private var checkedBytes: Int64 { checkedNodes.reduce(0) { $0 + $1.allocatedSize } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.duplicateProgress == nil, let d = state.duplicates, !d.groups.isEmpty {
                nextStep
                Divider()
            }
            if state.root == nil {
                placeholder("Scan a folder first, then look for duplicates inside it.", symbol: "folder.badge.questionmark")
            } else if let p = state.duplicateProgress {
                progress(p)
            } else if let d = state.duplicates {
                if d.groups.isEmpty {
                    placeholder("No duplicate files of 1 MB or more \(state.rootLocation?.phrase ?? "in this folder").", symbol: "checkmark.circle")
                } else {
                    list
                }
            } else {
                start
            }
        }
        // The inspector follows the copy you click here, not a folder picked in another view.
        .onAppear { state.selectedNode = nil }
        .onDisappear {
            if let id = state.selection.first { state.selectedNode = state.node(for: id) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate files").font(.headline)
                if let d = state.duplicates, !d.groups.isEmpty {
                    Text("\(d.wasted.humanBytes) reclaimable · \(d.groups.count.formatted()) groups · files of 1 MB and more, compared byte for byte")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Files that exist more than once with identical content.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.duplicates != nil && state.duplicateProgress == nil {
                TextField("Filter by path", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
                Button { state.findDuplicates() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Says what to do with the results: pick the extra copies, then remove them.
    private var nextStep: some View {
        HStack(spacing: 12) {
            if checked.isEmpty {
                Image(systemName: "hand.point.up.left").font(.title3).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose which copies to remove").font(.callout.weight(.semibold))
                    Text("Tick copies yourself, or let Headroom pick the extra copies in every group. One copy of each file always stays, and copies marked Do not delete are never picked for you.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Menu("Other ways") {
                    Button("Keep oldest copy, select the rest") { select(keep: .oldest) }
                    Button("Keep the copy highest in the tree, select the rest") { select(keep: .shallowest) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Keep the oldest copy, or the one highest in the folder tree, instead of the newest")
                Button("Select extra copies (keep newest)") { select(keep: .newest) }
                    .buttonStyle(.borderedProminent)
                    .help("Ticks every copy except the newest one in each group")
            } else {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(checked.count.formatted()) \(checked.count == 1 ? "copy" : "copies") selected · \(checkedBytes.humanBytes)")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                    Text(state.deleteMode == .trash
                         ? "They go to the Trash, so you can put them back. Unticked copies stay where they are."
                         : "Permanent mode: they are deleted right away, with no undo. Unticked copies stay where they are.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Clear") { checked = [] }
                Button(role: .destructive) {
                    requestDelete(checkedNodes)
                    checked = []
                } label: {
                    Label(removeLabel, systemImage: state.deleteMode.symbol)
                }
                .buttonStyle(.borderedProminent)
                .tint(state.deleteMode == .permanent ? .red : nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.06))
    }

    private var removeLabel: String {
        let copies = "\(checked.count.formatted()) \(checked.count == 1 ? "copy" : "copies")"
        return state.deleteMode == .trash
            ? "Move \(copies) to Trash (\(checkedBytes.humanBytes))"
            : "Delete \(copies) permanently (\(checkedBytes.humanBytes))"
    }

    // MARK: States

    private var start: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.doc").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("Find duplicate files \(state.rootLocation?.phrase ?? "in the scanned folder")").font(.title3.weight(.semibold))
            Text("Files are grouped by size, then compared by content hash, so only true byte-for-byte copies are listed. Files inside app bundles and files under 1 MB are skipped.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            Button("Find duplicates") { state.findDuplicates() }.buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progress(_ p: DuplicateProgress) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: p.fraction).frame(width: 320)
            Text(p.phase.isEmpty ? "Preparing…" : p.phase).font(.headline)
            Text(p.total > 0 ? "\(p.done.formatted()) of \(p.total.formatted()) candidate files · \(p.bytes.humanBytes) read" : "\(p.bytes.humanBytes) read")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            Text(p.current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 480)
            Button("Cancel") { state.cancelDuplicateScan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private var list: some View {
        List {
            ForEach(groups.prefix(shown)) { g in
                let folder = sharedFolder(of: g)
                let open = expanded.contains(g.id) || g.count <= collapsedCopies + 1
                let ticked = g.files.reduce(0) { $0 + (checked.contains($1.id) ? 1 : 0) }
                Section {
                    ForEach(open ? g.files : Array(g.files.prefix(collapsedCopies))) { f in
                        row(f, in: g, sharedFolder: folder, ticked: ticked)
                    }
                    if g.count > collapsedCopies + 1 {
                        Button {
                            if open { expanded.remove(g.id) } else { expanded.insert(g.id) }
                        } label: {
                            Label(open ? "Show fewer copies" : "Show \((g.count - collapsedCopies).formatted()) more copies",
                                  systemImage: open ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                        .padding(.leading, 28)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: g.files.first?.iconName ?? "doc")
                            .foregroundStyle(g.files.first?.effectiveCategory.color ?? .secondary)
                        Text(g.files.first?.name ?? "").lineLimit(1)
                        Text("· \(g.count) copies · \(g.size.humanBytes) each").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(g.wasted.humanBytes) reclaimable").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            if groups.count > shown {
                Section {
                    HStack {
                        Spacer()
                        Button("Show \(min(200, groups.count - shown)) more of \(groups.count.formatted()) groups") { shown += 200 }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .listStyle(.inset)
        .onChange(of: filter) { _, _ in shown = 150 }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Toggle("Always keep at least one copy of each file", isOn: $keepOneCopy)
                    .toggleStyle(.checkbox)
                    .help("While on, the last unticked copy in a group can't be ticked.")
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
        .onChange(of: keepOneCopy) { _, on in if on { enforceKeepOne() } }
    }

    private func row(_ f: FileNode, in g: DuplicateGroup, sharedFolder: String, ticked: Int) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { checked.contains(f.id) },
                set: { on in
                    if on {
                        if keepOneCopy && ticked >= g.count - 1 { return }
                        checked.insert(f.id)
                    } else { checked.remove(f.id) }
                }
            ))
            .toggleStyle(.checkbox).labelsHidden()
            .help(keepOneCopy && !checked.contains(f.id) && ticked >= g.count - 1
                  ? "This is the last copy left. Turn off \"Always keep at least one copy\" to remove it too."
                  : "Tick to remove this copy")
            VStack(alignment: .leading, spacing: 2) {
                Text(distinctPart(of: f, sharedFolder: sharedFolder))
                    .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Text("in " + (sharedFolder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let m = f.modified {
                        Text("· \(m.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary).fixedSize()
                    }
                    if f.id == g.files.first?.id { tag("newest") }
                }
                .font(.caption)
            }
            .help(f.path)
            Spacer()
            SafetyBadge(info: SafetyKB.info(for: f))
            Button { state.revealInFinder(f) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(state.selectedNode === f ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { state.selectedNode = f }
        .contextMenu {
            Button("Reveal in Finder") { state.revealInFinder(f) }
            Button("Keep this one, select the other \(g.count - 1)") {
                for o in g.files where o.id != f.id { checked.insert(o.id) }
                checked.remove(f.id)
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(.secondary.opacity(0.18), in: Capsule())
    }

    // MARK: Paths

    /// Deepest folder every copy in the group lives under.
    private func sharedFolder(of g: DuplicateGroup) -> String {
        guard var common = g.files.first?.url.deletingLastPathComponent().pathComponents else { return "/" }
        for f in g.files.dropFirst() {
            let parts = f.url.deletingLastPathComponent().pathComponents
            var n = 0
            while n < min(common.count, parts.count) && common[n] == parts[n] { n += 1 }
            common.removeLast(common.count - n)
            if common.count <= 1 { break }
        }
        return NSString.path(withComponents: common.isEmpty ? ["/"] : common)
    }

    /// What tells this copy apart: its path below the shared folder ("2023/IMG_4021.heic").
    private func distinctPart(of f: FileNode, sharedFolder: String) -> String {
        let prefix = sharedFolder.hasSuffix("/") ? sharedFolder : sharedFolder + "/"
        return f.path.hasPrefix(prefix) ? String(f.path.dropFirst(prefix.count)) : f.name
    }

    // MARK: Selection helpers

    private enum Keep { case newest, oldest, shallowest }

    private func select(keep: Keep) {
        var next = checked
        for g in groups {
            let keeper: FileNode?
            switch keep {
            case .newest: keeper = g.files.first                       // sorted newest first
            case .oldest: keeper = g.files.last
            case .shallowest: keeper = g.files.min { $0.url.pathComponents.count < $1.url.pathComponents.count }
            }
            for f in g.files {
                // Never auto-pick a copy marked "Do not delete" (e.g. inside .git); tick it by hand if you mean it.
                if f.id == keeper?.id || SafetyKB.level(for: f) == .never { next.remove(f.id) } else { next.insert(f.id) }
            }
        }
        checked = next
    }

    private func enforceKeepOne() {
        for g in groups where g.files.allSatisfy({ checked.contains($0.id) }) {
            if let first = g.files.first { checked.remove(first.id) }
        }
    }
}
