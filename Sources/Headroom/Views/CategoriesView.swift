import SwiftUI
import Charts

struct CategoriesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.requestDelete) private var requestDelete
    @State private var selected: FileCategory?
    @State private var hovered: FileCategory?
    @State private var items: [FileNode] = []
    @State private var itemSelection: Set<FileNode.ID> = []

    private let onSelect: (FileCategory?) -> Void

    init(initial: FileCategory? = nil, onSelect: @escaping (FileCategory?) -> Void = { _ in }) {
        _selected = State(initialValue: initial)
        self.onSelect = onSelect
    }

    private struct Row: Identifiable {
        let category: FileCategory
        let bytes: Int64
        var id: FileCategory { category }
    }
    private var rows: [Row] {
        state.categoryTotals
            .filter { $0.value > 0 }
            .map { Row(category: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
    }
    private var total: Int64 { rows.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("What is using the space").font(.title3.bold())
                Chart(rows) { row in
                    BarMark(x: .value("Size", row.bytes), y: .value("Category", row.category.title))
                        .foregroundStyle(row.category.color)
                        .opacity(barOpacity(row.category))
                        .annotation(position: .trailing) {
                            Text(row.bytes.humanBytes).font(.caption).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Int64.self) { Text(v == 0 ? "0" : v.humanBytes) } }
                    }
                }
                .chartYAxis { AxisMarks { AxisValueLabel() } }
                .chartOverlay { proxy in
                    // The whole row is the target: label, bar and the empty space after a short bar.
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let p):
                                    hovered = category(at: p, proxy: proxy, geo: geo)
                                    (hovered == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
                                case .ended:
                                    hovered = nil
                                    NSCursor.arrow.set()
                                }
                            }
                            .onTapGesture { p in
                                guard let cat = category(at: p, proxy: proxy, geo: geo) else { return }
                                selected = selected == cat ? nil : cat
                            }
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hovered)
                .help("Click a bar to list the largest items in that category")
                .frame(height: CGFloat(max(1, rows.count)) * 30 + 30)

                ScrollViewReader { scroller in
                    List(rows, selection: $selected) { row in
                        HStack {
                            Image(systemName: row.category.symbol).foregroundStyle(row.category.color).frame(width: 20)
                            Text(row.category.title)
                            Spacer()
                            Text(total > 0 ? Double(row.bytes) / Double(total) : 0, format: .percent.precision(.fractionLength(1)))
                                .foregroundStyle(.secondary).monospacedDigit()
                            Text(row.bytes.humanBytes).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        .tag(row.category)
                        .id(row.category)
                    }
                    .onChange(of: selected) { _, cat in
                        if let cat { withAnimation { scroller.scrollTo(cat) } }
                    }
                }
            }
            .padding()
            .frame(minWidth: 300)

            VStack(spacing: 0) {
                HStack {
                    if let selected {
                        Label("Largest \(selected.title.lowercased())", systemImage: selected.symbol)
                            .font(.headline)
                    } else {
                        Text("Select a category to list its largest items").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        requestDelete(items.filter { itemSelection.contains($0.id) })
                    } label: { Label(state.deleteMode.actionLabel, systemImage: state.deleteMode.symbol) }
                .tint(state.deleteMode == .permanent ? .red : nil)
                    .disabled(itemSelection.isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                FileListTable(items: items, selection: $itemSelection)
            }
            .frame(minWidth: 260)
        }
        .onChange(of: selected) { _, cat in reload(cat); onSelect(cat) }
        .onChange(of: state.categoryTotals.count) { _, _ in reload(selected) }
        .onAppear { reload(selected) }
    }

    private func barOpacity(_ cat: FileCategory) -> Double {
        if selected == nil || selected == cat { return 1 }
        return hovered == cat ? 0.8 : 0.35   // a faded bar lifts on hover; a full one stays full
    }

    private func category(at point: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> FileCategory? {
        guard let plot = proxy.plotFrame.map({ geo[$0] }),
              point.y >= plot.minY, point.y <= plot.maxY,
              let title: String = proxy.value(atY: point.y - plot.minY) else { return nil }
        return rows.first { $0.category.title == title }?.category
    }

    private func reload(_ cat: FileCategory?) {
        itemSelection = []
        guard let cat, let root = state.root else { items = []; return }
        var found: [FileNode] = []
        func visit(_ n: FileNode, inherited: FileCategory?) {
            let forced = n.category ?? inherited
            if n.isDirectory && !n.isPackage {
                // Whole forced subtree (e.g. node_modules) counts as one item.
                if let forced, n.category != nil, forced == cat { found.append(n); return }
                if let forced, forced != cat { return }
                for c in n.children { visit(c, inherited: forced) }
            } else if (forced ?? FileCategory.forFile(named: n.name)) == cat {
                found.append(n)
            }
        }
        visit(root, inherited: nil)
        found.sort { $0.allocatedSize > $1.allocatedSize }
        items = Array(found.prefix(200))
    }
}

/// Flat file table shared by the category and largest-files panes.
struct FileListTable: View {
    @EnvironmentObject var state: AppState
    @Environment(\.requestDelete) private var requestDelete
    let items: [FileNode]
    @Binding var selection: Set<FileNode.ID>

    var body: some View {
        Table(items, selection: $selection) {
            TableColumn("Name") { node in
                HStack(spacing: 6) {
                    Image(systemName: node.iconName).foregroundStyle(node.effectiveCategory.color).frame(width: 16)
                    Text(node.name).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Size") { node in
                Text(node.allocatedSize.humanBytes).monospacedDigit()
            }
            .width(90)
            TableColumn("Safe?") { node in
                SafetyBadge(info: SafetyKB.info(for: node))
            }
            .width(105)
            TableColumn("Location") { node in
                Text(node.url.deletingLastPathComponent().path)
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            TableColumn("Modified") { node in
                Text(node.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(100)
        }
        .contextMenu(forSelectionType: FileNode.ID.self) { ids in
            let nodes = items.filter { ids.contains($0.id) }
            if let one = nodes.first, nodes.count == 1 {
                Button("Reveal in Finder") { state.revealInFinder(one) }
                Divider()
            }
            Button(state.deleteMode.actionLabel, role: .destructive) { requestDelete(nodes) }
        }
        .onDeleteCommand { requestDelete(items.filter { selection.contains($0.id) }) }
        .onChange(of: selection) { _, sel in
            if let id = sel.first, let n = items.first(where: { $0.id == id }) { state.selectedNode = n }
        }
    }
}
