import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @Binding var pane: Pane
    @Binding var categoryFocus: FileCategory?
    @Environment(\.scenePhase) private var scenePhase
    @State private var volumeSpace: VolumeSpace?

    private struct VolumeSpace {
        let name: String
        let total: Int64
        let free: Int64
        var used: Int64 { total - free }
    }

    private struct CategoryRow: Identifiable {
        let category: FileCategory
        let bytes: Int64
        var id: FileCategory { category }
    }

    private var categories: [CategoryRow] {
        state.categoryTotals.filter { $0.value > 0 }
            .map { CategoryRow(category: $0.key, bytes: $0.value) }
            .sorted { $0.bytes == $1.bytes ? $0.category.title < $1.category.title : $0.bytes > $1.bytes }
    }

    private var cleanupBytes: Int64 {
        state.cleanupCandidates.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        if let root = state.root {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(root)
                    diskSpaceCard
                    FreeSpaceTrendCard()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        statistic("Size on disk", value: root.allocatedSize.humanBytes,
                                  note: "\(root.logicalSize.humanBytes) logical size", symbol: "internaldrive", color: .purple,
                                  destination: .treemap)
                        statistic("Files", value: root.fileCount.formatted(),
                                  note: "Inside the scanned folder", symbol: "doc.on.doc", color: .blue,
                                  destination: .largest)
                        statistic("Folders", value: root.directoryCount.formatted(),
                                  note: "Excludes the scanned root", symbol: "folder", color: .orange,
                                  destination: .tree)
                        statistic("Cleanup candidates", value: cleanupBytes.humanBytes,
                                  note: "\(state.cleanupCandidates.count.formatted()) folders to review", symbol: "sparkles", color: .mint,
                                  destination: .cleanup)
                    }
                    duplicatesCard

                    card {
                        sectionHeader("Space by category", destination: .categories)
                        let rows = categories
                        if rows.isEmpty {
                            emptyMessage("No categorized file data in this folder.")
                        } else {
                            let total = rows.reduce(Int64(0)) { $0 + $1.bytes }
                            Chart(rows) { row in
                                BarMark(x: .value("Size", row.bytes), y: .value("Category", row.category.title))
                                    .foregroundStyle(row.category.color)
                                    .cornerRadius(4)
                                    .accessibilityLabel(row.category.title)
                                    .accessibilityValue(row.bytes.humanBytes)
                            }
                            .chartXAxis {
                                AxisMarks { value in
                                    AxisGridLine()
                                    AxisValueLabel {
                                        if let bytes = value.as(Int64.self) { Text(bytes == 0 ? "0" : bytes.humanBytes) }
                                    }
                                }
                            }
                            .chartOverlay { proxy in
                                GeometryReader { geo in
                                    Rectangle().fill(.clear).contentShape(Rectangle())
                                        .onTapGesture { p in
                                            guard let plot = proxy.plotFrame.map({ geo[$0] }),
                                                  let title: String = proxy.value(atY: p.y - plot.minY),
                                                  let row = rows.first(where: { $0.category.title == title }) else { return }
                                            openCategory(row.category)
                                        }
                                        .linkCursor()
                                }
                            }
                            .help("Click a bar to open it in By Category")
                            .frame(height: CGFloat(rows.count) * 28 + 30)
                            ForEach(rows) { row in
                                Button { openCategory(row.category) } label: {
                                    HStack {
                                        Label(row.category.title, systemImage: row.category.symbol)
                                            .foregroundStyle(row.category.color)
                                        Spacer()
                                        Text(Double(row.bytes) / Double(max(1, total)), format: .percent.precision(.fractionLength(1)))
                                            .foregroundStyle(.secondary)
                                        Text(row.bytes.humanBytes).frame(minWidth: 80, alignment: .trailing)
                                    }
                                    .font(.callout).monospacedDigit()
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .linkCursor()
                                .help("Open \(row.category.title) in By Category")
                            }
                        }
                    }

                    card {
                        sectionHeader("Largest files & apps", destination: .largest)
                        if state.largest.isEmpty {
                            emptyMessage("No files found in this folder.")
                        } else {
                            ForEach(Array(state.largest.prefix(5))) { node in
                                Button {
                                    state.selection = [node.id]
                                    state.selectedNode = node
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: node.iconName)
                                            .foregroundStyle(node.effectiveCategory.color).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(node.name).foregroundStyle(.primary).lineLimit(1)
                                            Text(node.path).font(.caption).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer(minLength: 12)
                                        Text(node.allocatedSize.humanBytes).monospacedDigit().foregroundStyle(.primary)
                                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                                    }
                                    .padding(8)
                                    .background(state.selectedNode === node ? Color.accentColor.opacity(0.1) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Inspect \(node.name)")
                            }
                        }
                    }

                    card {
                        sectionHeader("Cleanup overview", destination: .cleanup)
                        Text(state.cleanupCandidates.isEmpty
                             ? "No cleanup candidates found in the scanned folder."
                             : "Review \(cleanupBytes.humanBytes) of dependencies, build output, caches and other cleanup candidates before removing anything.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("File and cleanup statistics cover the scanned folder. Disk space covers its entire volume and refreshes automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .task(id: root.id) {
                refreshDiskSpace()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) }
                    catch { return }
                    refreshDiskSpace()
                }
            }
            .onChange(of: state.deleting == nil) { _, finished in
                if finished { refreshDiskSpace() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshDiskSpace() }
            }
        }
    }

    private var duplicatesCard: some View {
        card {
            HStack {
                Label("Duplicate files", systemImage: "doc.on.doc").font(.headline)
                Spacer()
                if state.duplicates != nil {
                    Button("View all") { pane = .duplicates }.buttonStyle(.link)
                }
            }
            if let p = state.duplicateProgress {
                HStack(spacing: 10) {
                    ProgressView(value: p.fraction).frame(maxWidth: 260)
                    Text(p.phase.isEmpty ? "Preparing…" : "\(p.phase)… \(p.done.formatted()) of \(p.total.formatted())").font(.callout).foregroundStyle(.secondary)
                }
            } else if let d = state.duplicates {
                if d.groups.isEmpty {
                    Text("No duplicate files of 1 MB or more in this folder.").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(d.wasted.humanBytes).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("in \(d.groups.count.formatted()) groups of identical files").foregroundStyle(.secondary)
                        Spacer()
                        Button("Review and clean") { pane = .duplicates }
                    }
                    Text("Space you get back by keeping one copy of each.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("Find files that exist more than once, byte for byte, and keep only one copy.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Find duplicates") { state.findDuplicates() }
                }
            }
        }
    }

    private var diskSpaceCard: some View {
        card {
            HStack {
                Label("Disk space", systemImage: "internaldrive").font(.headline)
                Spacer()
                Button { refreshDiskSpace() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.link)
            }
            if let space = volumeSpace {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(space.free.humanBytes)
                        .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("free").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(space.total.humanBytes) total").foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: Double(space.used), total: Double(space.total))
                    .tint(.purple)
                    .accessibilityLabel("Disk space used")
                    .accessibilityValue("\(space.used.humanBytes) of \(space.total.humanBytes)")
                HStack {
                    Text(space.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(space.used.humanBytes) used · \(Int((Double(space.free) / Double(space.total) * 100).rounded()))% free")
                        .monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                Text("Entire volume containing the scanned folder · refreshes every 15 seconds. Moving files to Trash does not free disk space until it is emptied.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Disk space is unavailable for this volume. Try refreshing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func refreshDiskSpace() {
        guard let path = state.root?.path else { volumeSpace = nil; return }
        // A fresh URL avoids cached capacity values after cleanup or external writes.
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ]), let total = values.volumeTotalCapacity, total > 0,
           let free = values.volumeAvailableCapacity else {
            volumeSpace = nil
            return
        }
        volumeSpace = VolumeSpace(name: values.volumeName ?? "Scanned volume",
                                  total: Int64(total), free: min(Int64(total), max(0, Int64(free))))
    }

    private func header(_ root: FileNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dashboard", systemImage: "chart.bar.xaxis")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Label(state.rootLocation?.summary ?? root.path, systemImage: state.rootLocation?.symbol ?? "folder")
                .font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .help(root.path)
            HStack(spacing: 12) {
                if let finished = state.progress.finished {
                    Text("Scanned \(finished.formatted(date: .abbreviated, time: .shortened))")
                }
                Text(String(format: "%.1fs", state.progress.elapsed))
            }
            .font(.caption).foregroundStyle(.white.opacity(0.8))
            if state.progress.errors > 0 {
                Label("\(state.progress.errors.formatted()) unreadable items · totals may be incomplete", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { BrandBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func openCategory(_ category: FileCategory) {
        categoryFocus = category
        pane = .categories
    }

    private func statistic(_ title: String, value: String, note: String, symbol: String, color: Color,
                           destination: Pane) -> some View {
        Button { pane = destination } label: {
            card {
                HStack {
                    Label(title, systemImage: symbol).font(.callout.weight(.medium)).foregroundStyle(color)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(StatTileButtonStyle())
        .help("Open \(destination.title)")
        .accessibilityLabel("\(title): \(value). Open \(destination.title)")
    }

    private func sectionHeader(_ title: String, destination: Pane) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button("View all") { pane = destination }.buttonStyle(.link)
                .accessibilityLabel("View \(destination.title)")
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.07)))
    }
}

/// Stat tiles are links to their pane: highlight on hover and press, pointing-hand cursor.
private struct StatTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    private struct Tile: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.08 : hovered ? 0.04 : 0))
                        .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(hovered ? 0.5 : 0))
                        .allowsHitTesting(false)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onHover { hovered = $0 }
                .linkCursor()
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}

extension View {
    /// Pointing-hand cursor while the pointer is over this view. Uses `set()` rather than
    /// push/pop so a view that disappears on click (navigation) can't leave the stack unbalanced.
    func linkCursor() -> some View {
        modifier(LinkCursor())
    }
}

private struct LinkCursor: ViewModifier {
    @State private var inside = false
    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    inside = true
                    NSCursor.pointingHand.set()
                case .ended:
                    inside = false
                    NSCursor.arrow.set()
                }
            }
            .onDisappear { if inside { NSCursor.arrow.set() } }
    }
}
