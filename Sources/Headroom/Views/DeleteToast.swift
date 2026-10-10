import SwiftUI

/// Animated "done" card shown after a delete: checkmark draws itself, the freed
/// size counts up, then it slides away. Errors get a Details button instead.
struct DeleteToast: View {
    let result: DeleteResult
    let mode: DeleteMode
    let dismiss: () -> Void

    @State private var drawn = false
    @State private var shown: Int64 = 0
    @State private var showErrors = false

    private var ok: Bool { result.errors.isEmpty }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(ok ? SafetyLevel.safe.color.opacity(0.18) : SafetyLevel.caution.color.opacity(0.18)).frame(width: 52, height: 52)
                Circle().trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(ok ? SafetyLevel.safe.color : SafetyLevel.caution.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 52, height: 52)
                    .animation(.easeOut(duration: 0.5), value: drawn)
                if ok {
                    Checkmark().trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(SafetyLevel.safe.color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 22, height: 18)
                        .animation(.easeOut(duration: 0.35).delay(0.35), value: drawn)
                } else {
                    Image(systemName: "exclamationmark").font(.title2.bold()).foregroundStyle(SafetyLevel.caution.color)
                        .scaleEffect(drawn ? 1 : 0.3).animation(.spring(duration: 0.4, bounce: 0.4).delay(0.3), value: drawn)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(ok ? "Freed \(shown.humanBytes)" : "Freed \(shown.humanBytes) · \(result.errors.count) failed")
                    .font(.title3.bold().monospacedDigit())
                    .contentTransition(.numericText(value: Double(shown)))
                Text(Self.count(result.removedFiles, "file") + " · " + Self.count(result.removedDirectories, "folder") + (mode == .trash ? " moved to the Trash" : " removed"))
                    .font(.callout).foregroundStyle(.secondary)
                // Say why right here; a "Details" click should not be needed to learn that nothing happened.
                if let reason = result.errors.first?.message, !ok {
                    Text(reason).font(.callout).foregroundStyle(SafetyLevel.caution.color)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520, alignment: .leading)
                }
            }
            if !ok {
                // Finder is allowed through by every antivirus and can ask for an admin password,
                // so whatever Headroom could not remove, the user can finish there.
                ForEach(result.blockedBy.prefix(2)) { suite in
                    if let app = suite.appURL {
                        Button("Open \(suite.name)") { NSWorkspace.shared.open(app) }
                    }
                }
                Button("Reveal in Finder") { reveal() }
                Button("Details") { showErrors = true }
                    .alert("Some items could not be removed", isPresented: $showErrors) {
                        Button("How to Fix…") { NSWorkspace.shared.open(Deleter.trashHelpURL); dismiss() }
                        Button("OK") { dismiss() }
                    } message: {
                        Text(result.errors.prefix(8).map { "• \($0.path)\n  \($0.message)" }.joined(separator: "\n"))
                    }
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.caption.bold()) }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 4)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .onAppear {
            drawn = true
            countUp()
            if ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { dismiss() }
            }
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")" }

    private func reveal() {
        let urls = result.errors.prefix(20).map { URL(fileURLWithPath: $0.path) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func countUp() {
        let target = result.freedBytes
        guard target > 0 else { return }
        let steps = 24
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.035) {
                // ease-out curve
                let t = Double(i) / Double(steps)
                let eased = 1 - pow(1 - t, 3)
                withAnimation(.linear(duration: 0.03)) { shown = Int64(Double(target) * eased) }
            }
        }
    }
}

private struct Checkmark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + 1))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}
