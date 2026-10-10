import SwiftUI

/// Mesh-ish gradient backdrop shared by the welcome and scanning screens (matches the app icon).
struct BrandBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.31, green: 0.27, blue: 0.90),
                                    Color(red: 0.49, green: 0.23, blue: 0.93),
                                    Color(red: 0.05, green: 0.65, blue: 0.91)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                Ellipse().fill(.white.opacity(0.22)).frame(width: geo.size.width * 0.8, height: geo.size.height * 0.6)
                    .blur(radius: 60).offset(x: -geo.size.width * 0.2, y: -geo.size.height * 0.2)
                Ellipse().fill(Color.cyan.opacity(0.45)).frame(width: geo.size.width * 0.7, height: geo.size.height * 0.55)
                    .blur(radius: 60).offset(x: geo.size.width * 0.5, y: geo.size.height * 0.6)
            }
        }
    }
}

/// Frosted tile like the ones in the icon. `lit` tints it with a category color.
struct GlassTile: View {
    var lit: Color? = nil
    var radius: CGFloat = 18
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.white.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                // Lit color sits above the glass so it reads at full strength.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(lit ?? Color.clear)
                    .opacity(lit == nil ? 0 : 0.95)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.2)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
            )
            .shadow(color: lit.map { $0.opacity(0.55) } ?? .black.opacity(0.18), radius: lit != nil ? 14 : 8, y: 6)
            .scaleEffect(lit != nil ? 1.05 : 1)
            .animation(.easeOut(duration: 0.18), value: lit)
    }
}

/// The 5-tile bento from the icon, with an optional number of tiles lit.
/// `single == true` lights only tile `lit-1` (loader sweep) instead of the first `lit` tiles.
struct BentoTiles: View {
    var lit: Int = 0
    var single = false
    private let colors: [Color] = [.yellow, .pink, .mint, .orange, .cyan]
    private func on(_ i: Int) -> Bool { single ? lit == i + 1 : lit > i }
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let g = s * 0.04
            let big = s * 0.62
            let side = s - big - g
            ZStack(alignment: .topLeading) {
                GlassTile(lit: on(0) ? colors[0] : nil, radius: s * 0.09).frame(width: big, height: big)
                GlassTile(lit: on(1) ? colors[1] : nil, radius: s * 0.07).frame(width: side, height: big * 0.55 - g / 2).offset(x: big + g)
                GlassTile(lit: on(2) ? colors[2] : nil, radius: s * 0.07).frame(width: side, height: big * 0.45 - g / 2).offset(x: big + g, y: big * 0.55 + g / 2)
                GlassTile(lit: on(3) ? colors[3] : nil, radius: s * 0.07).frame(width: s * 0.45, height: side).offset(y: big + g)
                GlassTile(lit: on(4) ? colors[4] : nil, radius: s * 0.07).frame(width: s - s * 0.45 - g, height: side).offset(x: s * 0.45 + g, y: big + g)
            }
            .frame(width: s, height: s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            BrandBackground()
            VStack(spacing: 28) {
                Spacer(minLength: 0)
                HStack(spacing: 24) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().interpolation(.high)
                        .frame(width: 128, height: 128)
                        .shadow(color: .black.opacity(0.3), radius: 16, y: 10)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Headroom").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        Text("See what's eating your disk. Clean it in one click.")
                            .font(.title3).foregroundStyle(.white.opacity(0.85))
                    }
                }

                HStack(spacing: 12) {
                    BigButton(title: "Scan Folder…", symbol: "folder.badge.plus", primary: true) { state.pickFolder() }
                        .keyboardShortcut(.defaultAction)
#if !APP_STORE
                    BigButton(title: "Home", symbol: "house") { state.scan(URL(fileURLWithPath: NSHomeDirectory())) }
                    BigButton(title: "Startup Disk", symbol: "internaldrive") { state.scan(URL(fileURLWithPath: "/")) }
#endif
                }

                if !state.recentScans.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("RECENT").font(.caption.bold()).foregroundStyle(.white.opacity(0.6)).padding(.leading, 6)
                        ForEach(state.recentScans, id: \.path) { url in
                            let location = ScanLocation(url: url)
                            Button {
                                state.scan(url)
                            } label: {
                                HStack {
                                    Image(systemName: location.symbol).frame(width: 18)
                                    Text(location.name).lineLimit(1)
                                    if location.kind == .folder {
                                        Text(location.detail).lineLimit(1).truncationMode(.middle)
                                            .foregroundStyle(.white.opacity(0.55))
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.5))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 420)
                }
                Spacer(minLength: 0)
#if APP_STORE
                Text("Choose a folder to grant Headroom access. Other locations remain private.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55)).padding(.bottom, 12)
#else
                Text("Sizes are bytes allocated on disk. Grant Full Disk Access to see inside Mail, Messages and Safari data.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55)).padding(.bottom, 12)
#endif
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BigButton: View {
    let title: String
    let symbol: String
    var primary = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(primary ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.18)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(primary ? Color(red: 0.35, green: 0.25, blue: 0.9) : .white)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Shown while a scan runs: live counters plus the bento lighting up.
struct ScanningView: View {
    @EnvironmentObject var state: AppState
    @State private var lit = 0

    var body: some View {
        ZStack {
            BrandBackground()
            HStack(spacing: 48) {
                BentoLoader().frame(width: 220, height: 220)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Analyzing \(state.rootLocation?.name ?? "")")
                        .font(.title2.weight(.semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 28) {
                        Stat(value: state.progress.bytes.humanBytes, label: "found")
                        Stat(value: state.progress.files.formatted(), label: "files")
                        Stat(value: state.progress.directories.formatted(), label: "folders")
                    }
                    Text(state.progress.current)
                        .font(.caption.monospaced()).foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420, alignment: .leading)
                    Button("Stop") { state.cancelScan(); state.phase = .idle }
                        .buttonStyle(.bordered).tint(.white)
                }
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct Stat: View {
        let value: String
        let label: String
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(label).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}


/// Continuous loader: one tile sweeps around the bento, the rest stay frosted.
/// Driven by TimelineView (display-linked on the main run loop) so it keeps
/// ticking even when the scan saturates every core.
struct BentoLoader: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.42)) { ctx in
            let step = Int(ctx.date.timeIntervalSinceReferenceDate / 0.42) % 5 + 1
            BentoTiles(lit: step, single: true)
        }
    }
}
