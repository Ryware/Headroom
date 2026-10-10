import SwiftUI

/// Small colored pill with a tooltip explaining what the item is and whether it can go.
struct SafetyBadge: View {
    let info: SafetyInfo
    var compact = false

    private var tint: Color { info.level == .unknown ? Color.secondary : info.level.color }
    private var fill: Color { info.level == .unknown ? Color.clear : info.level.color.opacity(0.12) }
    private var border: Color { info.level == .unknown ? Color.clear : info.level.color.opacity(0.28) }
    private var tip: String { info.level.title + "\n\n" + info.what + "\n\n" + info.advice }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: info.level.symbol)
            if !compact { Text(info.level.short) }
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 2 : 7)
        .padding(.vertical, 2)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(border, lineWidth: 0.5))
        .help(tip)
    }
}

/// Right-hand panel with everything about the selected item.
struct InspectorView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.requestDelete) private var requestDelete

    var body: some View {
        if let node = state.selectedNode {
            let info = SafetyKB.info(for: node)
            // The scanned root goes by its location name ("Macintosh HD", not "/").
            let location = node === state.root ? state.rootLocation : nil
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: location?.symbol ?? node.iconName)
                            .font(.system(size: 28))
                            .foregroundStyle(node.isDirectory && !node.isPackage ? Color.accentColor : node.effectiveCategory.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(location?.name ?? node.name).font(.headline).lineLimit(2)
                            Text(node.allocatedSize.humanBytes).font(.title3.monospacedDigit())
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: info.level.symbol).foregroundStyle(info.level.color)
                                Text(info.level.title).font(.subheadline.bold()).foregroundStyle(info.level.color)
                                Spacer()
                                if !info.source.isEmpty {
                                    Text(info.source).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                            Text(info.what).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Text(info.advice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(4)
                    } label: {
                        Label("Can I delete this?", systemImage: "questionmark.circle")
                    }

                    GroupBox("Details") {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            if let location {
                                row("Scanned", location.detail)
                            } else {
                                row("Location", node.url.deletingLastPathComponent().path)
                            }
                            row("Category", node.effectiveCategory.title)
                            if node.isDirectory {
                                row("Files", node.fileCount.formatted())
                                row("Folders", node.directoryCount.formatted())
                            }
                            row("On disk", node.allocatedSize.humanBytes)
                            row("Logical", node.logicalSize.humanBytes)
                            if let m = node.modified {
                                row("Modified", m.formatted(date: .abbreviated, time: .shortened))
                            }
                            if node.parent != nil {
                                row("Of parent", node.shareOfParent.formatted(.percent.precision(.fractionLength(1))))
                            }
                        }
                        .font(.callout)
                        .padding(4)
                    }

                    if node.isDirectory && !node.isPackage && !node.children.isEmpty {
                        GroupBox("Largest inside") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(node.children.prefix(8)) { c in
                                    HStack {
                                        Image(systemName: c.iconName).foregroundStyle(c.effectiveCategory.color).frame(width: 14)
                                        Text(c.name).lineLimit(1)
                                        Spacer()
                                        Text(c.allocatedSize.humanBytes).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                }
                            }
                            .padding(4)
                        }
                    }

                    HStack {
                        Button { state.revealInFinder(node) } label: { Label("Reveal", systemImage: "magnifyingglass") }
                        Spacer()
                        Button(role: .destructive) { requestDelete([node]) } label: {
                            Label(state.deleteMode.actionLabel, systemImage: state.deleteMode.symbol)
                        }
                        .tint(state.deleteMode == .permanent ? .red : nil)
                        .disabled(info.level == .never)
                    }
                }
                .padding(14)
            }
        } else {
            VStack {
                Image(systemName: "sidebar.right").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Select an item to see what it is and whether it's safe to delete.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
}
