import SwiftUI

enum TreemapColorMode: String, CaseIterable, Identifiable {
    case category, age, safety
    var id: String { rawValue }
    var title: String {
        switch self {
        case .category: return "Category"
        case .age: return "Age"
        case .safety: return "Safety"
        }
    }
}

/// One laid-out rectangle in the treemap.
struct TreemapCell: Identifiable {
    let id: FileNode.ID
    let node: FileNode
    let rect: CGRect
    let depth: Int
    let isLeaf: Bool
}

/// Squarified treemap (Bruls, Huizing & van Wijk) with nested directories.
enum TreemapLayout {
    static let padding: CGFloat = 2
    static let headerHeight: CGFloat = 14
    static let minCell: CGFloat = 3

    static func layout(root: FileNode, in bounds: CGRect, maxDepth: Int) -> [TreemapCell] {
        var cells: [TreemapCell] = []
        place(root.children, in: bounds, depth: 0, maxDepth: maxDepth, into: &cells)
        return cells
    }

    private static func place(_ nodes: [FileNode], in rect: CGRect, depth: Int, maxDepth: Int, into cells: inout [TreemapCell]) {
        let items = nodes.filter { $0.allocatedSize > 0 }
        guard !items.isEmpty, rect.width >= minCell, rect.height >= minCell else { return }
        let total = items.reduce(0.0) { $0 + Double($1.allocatedSize) }
        guard total > 0 else { return }
        let area = Double(rect.width * rect.height)

        var remaining = rect
        var row: [(FileNode, Double)] = []
        var rowArea = 0.0

        func flush() {
            guard !row.isEmpty else { return }
            let horizontal = remaining.width >= remaining.height
            let side = horizontal ? Double(remaining.height) : Double(remaining.width)
            guard side > 0 else { row.removeAll(); return }
            let thickness = rowArea / side
            var offset = 0.0
            for (node, a) in row {
                let len = a / thickness
                let r: CGRect
                if horizontal {
                    r = CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: len)
                } else {
                    r = CGRect(x: remaining.minX + offset, y: remaining.minY, width: len, height: thickness)
                }
                offset += len
                emit(node, r, depth: depth, maxDepth: maxDepth, into: &cells)
            }
            if horizontal {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY, width: remaining.width - thickness, height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: remaining.height - thickness)
            }
            row.removeAll()
            rowArea = 0
        }

        for node in items {
            let a = Double(node.allocatedSize) / total * area
            if a < 0.5 { continue }
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row.map(\.1) + [a], rowArea + a, side) <= worst(row.map(\.1), rowArea, side) {
                row.append((node, a))
                rowArea += a
            } else {
                flush()
                row.append((node, a))
                rowArea = a
            }
        }
        flush()
    }

    /// Worst aspect ratio of a row of areas laid along `side`.
    private static func worst(_ areas: [Double], _ sum: Double, _ side: Double) -> Double {
        guard let mx = areas.max(), let mn = areas.min(), sum > 0, side > 0 else { return .infinity }
        let s2 = sum * sum, w2 = side * side
        return max(w2 * mx / s2, s2 / (w2 * mn))
    }

    private static func emit(_ node: FileNode, _ rect: CGRect, depth: Int, maxDepth: Int, into cells: inout [TreemapCell]) {
        let canNest = node.isDirectory && !node.isPackage && !node.children.isEmpty && depth < maxDepth
            && rect.width > 2 * padding + 12 && rect.height > headerHeight + 2 * padding + 8
        cells.append(TreemapCell(id: node.id, node: node, rect: rect, depth: depth, isLeaf: !canNest))
        if canNest {
            let inner = rect.insetBy(dx: padding, dy: padding)
            let body = CGRect(x: inner.minX, y: inner.minY + headerHeight, width: inner.width, height: inner.height - headerHeight)
            place(node.children, in: body, depth: depth + 1, maxDepth: maxDepth, into: &cells)
        }
    }
}

struct TreemapView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.requestDelete) private var requestDelete
    @State private var focus: FileNode?
    @State private var colorMode: TreemapColorMode = .category
    @State private var depth = 4
    @State private var hover: TreemapCell?
    @State private var hoverInfo: SafetyInfo = .unknown
    @State private var hoverPoint: CGPoint = .zero
    @State private var cells: [TreemapCell] = []
    /// One fill per cell, worked out when the layout or colour mode changes, never per frame.
    @State private var fills: [Color] = []
    @State private var drawVersion = 0
    @State private var lastSize: CGSize = .zero

    private var current: FileNode? { focus ?? state.root }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Equatable on (version, selection): hovering doesn't repaint every cell.
                    TreemapCanvas(cells: cells, fills: fills, selection: state.selection, version: drawVersion)
                    .equatable()
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            hoverPoint = p
                            setHover(hit(p))
                        case .ended:
                            setHover(nil)
                        }
                    }
                    .gesture(TapGesture(count: 2).onEnded {
                        if let c = hit(hoverPoint), c.node.isDirectory, !c.node.isPackage, !c.node.children.isEmpty {
                            focus = c.node
                            state.selectedNode = c.node
                        }
                    })
                    .simultaneousGesture(TapGesture(count: 1).onEnded {
                        if let c = hit(hoverPoint) {
                            state.selectedNode = c.node
                            state.selection = [c.node.id]
                        }
                    })
                    .contextMenu {
                        if let c = hover ?? hit(hoverPoint) {
                            Text(c.node.name)
                            Button("Reveal in Finder") { state.revealInFinder(c.node) }
                            if c.node.isDirectory && !c.node.isPackage {
                                Button("Zoom In") { focus = c.node }
                            }
                            Divider()
                            Button(state.deleteMode.actionLabel, role: .destructive) { requestDelete([c.node]) }
                        }
                    }

                    if let h = hover {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(.white.opacity(0.9), lineWidth: 1.5)
                            .frame(width: h.rect.width, height: h.rect.height)
                            .offset(x: h.rect.minX, y: h.rect.minY)
                            .allowsHitTesting(false)
                        tooltip(h, in: geo.size)
                    }
                }
                .onAppear { relayout(geo.size) }
                .onChange(of: geo.size) { _, s in relayout(s) }
                .onChange(of: focus) { _, _ in relayout(geo.size) }
                .onChange(of: depth) { _, _ in relayout(geo.size) }
                .onChange(of: state.root?.id) { _, _ in focus = nil; relayout(geo.size) }
                .onChange(of: state.lastDeleteResult?.freedBytes) { _, _ in relayout(geo.size) }
                .onChange(of: colorMode) { _, _ in recolor() }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            legend
        }
    }

    // MARK: Header / breadcrumb

    private var header: some View {
        HStack(spacing: 8) {
            if let root = state.root {
                let chain = ancestors(of: current ?? root, upTo: root)
                ForEach(Array(chain.enumerated()), id: \.element.id) { i, n in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(n.name) { focus = n === root ? nil : n }
                        .buttonStyle(.plain)
                        .fontWeight(n === (current ?? root) ? .semibold : .regular)
                }
                if let cur = current {
                    Text("· \(cur.allocatedSize.humanBytes)").foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                if let p = current?.parent, p !== state.root { focus = p } else { focus = nil }
            } label: {
                Label("Up", systemImage: "arrow.up")
            }
            .disabled(focus == nil)
            Picker("Color", selection: $colorMode) {
                ForEach(TreemapColorMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 220)
            Stepper("Depth \(depth)", value: $depth, in: 1...8).frame(width: 100)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                switch colorMode {
                case .category:
                    ForEach(FileCategory.allCases) { c in
                        HStack(spacing: 4) {
                            Circle().fill(c.color).frame(width: 8, height: 8)
                            Text(c.title)
                        }
                    }
                case .age:
                    ForEach(ageBuckets, id: \.label) { b in
                        HStack(spacing: 4) {
                            Circle().fill(b.color).frame(width: 8, height: 8)
                            Text(b.label)
                        }
                    }
                case .safety:
                    ForEach(SafetyLevel.allCases, id: \.self) { l in
                        HStack(spacing: 4) {
                            Circle().fill(l == .unknown ? Color.gray : l.color).frame(width: 8, height: 8)
                            Text(l.title)
                        }
                    }
                }
                Spacer()
                Text("Click: select · Double-click: zoom in · Right-click: actions").foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private func ancestors(of node: FileNode, upTo root: FileNode) -> [FileNode] {
        var chain: [FileNode] = []
        var n: FileNode? = node
        while let x = n {
            chain.append(x)
            if x === root { break }
            n = x.parent
        }
        return chain.reversed()
    }

    // MARK: Layout / drawing

    private func relayout(_ size: CGSize) {
        lastSize = size
        setHover(nil)
        guard let cur = current else { cells = []; recolor(); return }
        cells = TreemapLayout.layout(root: cur, in: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2), maxDepth: depth)
        recolor()
    }

    private func recolor() {
        fills = cells.map { color(for: $0.node) }
        drawVersion &+= 1
    }

    private func setHover(_ cell: TreemapCell?) {
        guard cell?.id != hover?.id else { return }
        hover = cell
        hoverInfo = cell.map { SafetyKB.info(for: $0.node) } ?? .unknown
    }

    private func hit(_ p: CGPoint) -> TreemapCell? {
        // Deepest cell containing the point wins.
        var best: TreemapCell?
        for c in cells where c.rect.contains(p) {
            if best == nil || c.depth > best!.depth { best = c }
        }
        return best
    }

    private let ageBuckets: [(label: String, days: Double, color: Color)] = [
        ("< 1 week", 7, Color(hue: 0.33, saturation: 0.6, brightness: 0.85)),
        ("< 1 month", 30, Color(hue: 0.25, saturation: 0.6, brightness: 0.85)),
        ("< 6 months", 182, Color(hue: 0.15, saturation: 0.7, brightness: 0.9)),
        ("< 1 year", 365, Color(hue: 0.08, saturation: 0.75, brightness: 0.9)),
        ("< 3 years", 1095, Color(hue: 0.02, saturation: 0.75, brightness: 0.85)),
        ("older", .infinity, Color(hue: 0.95, saturation: 0.6, brightness: 0.6)),
    ]

    private func color(for node: FileNode) -> Color {
        switch colorMode {
        case .category:
            return node.effectiveCategory.color
        case .age:
            let days = node.modified.map { -$0.timeIntervalSinceNow / 86400 } ?? .infinity
            return ageBuckets.first { days < $0.days }?.color ?? ageBuckets.last!.color
        case .safety:
            let l = SafetyKB.level(for: node)
            return l == .unknown ? Color.gray : l.color
        }
    }

    private func tooltip(_ c: TreemapCell, in size: CGSize) -> some View {
        let info = hoverInfo
        let w: CGFloat = 300
        let x = min(max(8, hoverPoint.x + 14), size.width - w - 8)
        let y = min(max(8, hoverPoint.y + 18), size.height - 120)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: c.node.iconName).foregroundStyle(c.node.effectiveCategory.color)
                Text(c.node.name).font(.headline).lineLimit(1)
                Spacer()
                Text(c.node.allocatedSize.humanBytes).font(.headline.monospacedDigit())
            }
            Text(c.node.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                Text(c.node.effectiveCategory.title)
                if c.node.isDirectory { Text("· \(c.node.fileCount.formatted()) files") }
                if let m = c.node.modified { Text("· \(m.formatted(.relative(presentation: .named)))") }
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: info.level.symbol).foregroundStyle(info.level.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.level.title).font(.caption.bold()).foregroundStyle(info.level.color)
                    Text(info.what).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(width: w, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 6)
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }
}

/// The map itself. Redraws only when the layout, colours or selection change.
private struct TreemapCanvas: View, Equatable {
    let cells: [TreemapCell]
    let fills: [Color]
    let selection: Set<FileNode.ID>
    let version: Int

    static func == (a: Self, b: Self) -> Bool { a.version == b.version && a.selection == b.selection }

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, _ in draw(in: ctx) }
    }

    private func draw(in ctx: GraphicsContext) {
        for (i, c) in cells.enumerated() {
            let base = i < fills.count ? fills[i] : .gray
            let r = c.rect
            if c.isLeaf {
                // Leaf: filled tile with a subtle bevel.
                ctx.fill(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2), with: .linearGradient(
                    Gradient(colors: [base.opacity(0.95), base.opacity(0.6)]),
                    startPoint: r.origin, endPoint: CGPoint(x: r.maxX, y: r.maxY)))
                if r.width > 40 && r.height > 14 {
                    let label = Text(c.node.name).font(.system(size: 10, weight: .medium)).foregroundColor(.white)
                    ctx.draw(label, in: r.insetBy(dx: 4, dy: 2))
                    if r.height > 30 {
                        let sz = Text(c.node.allocatedSize.humanBytes).font(.system(size: 9)).foregroundColor(.white.opacity(0.85))
                        ctx.draw(sz, in: CGRect(x: r.minX + 4, y: r.minY + 14, width: r.width - 8, height: 12))
                    }
                }
            } else {
                // Directory frame with header strip.
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(base.opacity(0.18)))
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3), with: .color(base.opacity(0.7)), lineWidth: 1)
                let header = CGRect(x: r.minX + 3, y: r.minY + 1, width: r.width - 6, height: TreemapLayout.headerHeight)
                let label = Text("\(c.node.name)  \(c.node.allocatedSize.humanBytes)")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.primary.opacity(0.85))
                ctx.draw(label, in: header)
            }
            if selection.contains(c.id) {
                ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white), lineWidth: 2)
            }
        }
    }
}
