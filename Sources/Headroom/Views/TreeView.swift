import SwiftUI

extension FileNode {
    /// Children for outline-style presentation; nil makes the row a leaf.
    var outlineChildren: [FileNode]? {
        (isDirectory && !isPackage && !children.isEmpty) ? children : nil
    }
    var iconName: String {
        if isSymlink { return "link" }
        if isPackage { return "app.fill" }
        if isDirectory { return "folder.fill" }
        return effectiveCategory.symbol
    }
}

struct TreeView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.requestDelete) private var requestDelete

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            OutlineTreeView()
        }
    }

    private var header: some View {
        HStack {
            if let root = state.root {
                Image(systemName: state.rootLocation?.symbol ?? "folder").foregroundStyle(.secondary)
                Text(state.rootLocation?.summary ?? root.path).font(.callout).lineLimit(1).truncationMode(.middle)
                    .help(root.path)
                Text("· \(root.allocatedSize.humanBytes)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) { requestDelete(state.selectedNodes) } label: {
                Label(state.deleteMode.actionLabel, systemImage: state.deleteMode.symbol)
            }
            .tint(state.deleteMode == .permanent ? .red : nil)
            .disabled(state.selection.isEmpty || state.deleting != nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct SizeBar: View {
    let fraction: Double
    let label: String
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.75))
                        .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 10)
            Text(label).monospacedDigit().frame(width: 72, alignment: .trailing)
        }
    }
}
