import SwiftUI

/// Bump when "What's new" changes; the intro re-opens on the What's New page for existing users.
let currentIntroVersion = 8

struct IntroPage: Identifiable {
    let id: Int
    static let welcome = IntroPage(id: 0)
    static var whatsNew: IntroPage { IntroPage(id: steps.count - 1) }
}

struct IntroStep: Identifiable {
    let id: Int
    let eyebrow: String
    let title: String
    let bullets: [(symbol: String, text: String)]
    let art: Art
    enum Art { case hero, scan, tree, treemap, safety, clean, menuBar, duplicates, whatsNew }
}

private let steps: [IntroStep] = [
    IntroStep(id: 0, eyebrow: "WELCOME", title: "Headroom",
              bullets: [("bolt.fill", "Scans a million files in seconds"),
                        ("square.grid.3x3.square", "Shows where the space goes, by folder, type and age"),
                        ("checkmark.shield.fill", "Tells you what is safe to delete — and what isn't")],
              art: .hero),
    IntroStep(id: 1, eyebrow: "STEP 1", title: "Scan",
              bullets: [("folder.badge.plus", "Pick any folder or a whole volume — ⌘O"),
                        ("house", "\"Home\" is the right start for most Macs"),
                        ("stop.circle", "Stop any time; results stay in memory, Rescan is ⌘R")],
              art: .scan),
    IntroStep(id: 2, eyebrow: "STEP 2", title: "Understand",
              bullets: [("list.bullet.indent", "Folder Tree: sizes on disk, bars show share of parent"),
                        ("square.grid.3x3.square", "Treemap: big tiles are big files. Double-click to zoom"),
                        ("chart.pie", "By Category and Largest Files answer \"what is this?\"")],
              art: .treemap),
    IntroStep(id: 3, eyebrow: "STEP 3", title: "Is it safe?",
              bullets: [("checkmark.shield.fill", "Green: regenerates itself (caches, node_modules, build output)"),
                        ("exclamationmark.triangle.fill", "Orange: app or user data — read the note in the Inspector"),
                        ("xmark.octagon.fill", "Red: never delete (Keychains, Mail, Photos library)")],
              art: .safety),
    IntroStep(id: 4, eyebrow: "STEP 4", title: "Clean",
              bullets: [("sparkles", "Cleanup finds junk inside the scan and in known caches"),
                        ("trash", "Trash mode: recoverable from the Trash, frees space later"),
                        ("flame", "Permanent mode: parallel delete, instant, no undo")],
              art: .clean),
    IntroStep(id: 5, eyebrow: "WHAT'S NEW IN 1.0", title: "Duplicate finder",
              bullets: [("doc.on.doc", "Finds files that exist more than once, compared byte for byte"),
                        ("arrow.down.right.and.arrow.up.left", "Grouped by how much space one copy gives back"),
                        ("checkmark.circle", "Keep newest, oldest or pick by hand. One copy always stays"),
                        ("gauge.with.dots.needle.33percent", "Fast: size, then a 64 KB prefix, then a full hash")],
              art: .duplicates),
    IntroStep(id: 6, eyebrow: "ALSO IN 1.0", title: "Hello, Headroom",
              bullets: [("sparkles", "DiskTree is now Headroom: the room your disk has left"),
                        ("chart.pie", "Menu bar ring, 7-day trend and local alerts (from 0.2)"),
                        ("checkmark.shield", "Same app, same settings, same bundle. Nothing to reinstall")],
              art: .menuBar),
    IntroStep(id: 7, eyebrow: "NEW IN 1.0.5", title: "Click anywhere, come right back",
              bullets: [("cursorarrow.click", "Dashboard tiles and category charts open their views"),
                        ("arrow.uturn.backward", "Go back with ⌘[ or ⌘←, forward with ⌘], any view with ⌘1–⌘7"),
                        ("doc.on.doc", "Duplicates picks the extra copies for you in one click")],
              art: .whatsNew),
]

struct IntroView: View {
    @Environment(\.dismiss) private var dismiss
    @State var page: Int = 0
    @State private var revealed = 0            // bullets shown on the current page
    @State private var artTick = 0             // drives per-page art animation
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            BrandBackground()
            VStack(spacing: 0) {
                HStack(spacing: 36) {
                    artView.frame(width: 260, height: 260)
                    textView.frame(width: 340, alignment: .leading)
                }
                .padding(.horizontal, 40).padding(.top, 36)
                .frame(maxHeight: .infinity)
                footer
            }
        }
        .frame(width: 760, height: 460)
        .onAppear { reveal(); installArrowKeys() }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        .onChange(of: page) { _, _ in reveal() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                artTick += 1
            }
        }
    }

    private var step: IntroStep { steps[page] }

    // MARK: text

    private var textView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(step.eyebrow).font(.caption.bold()).tracking(1.5).foregroundStyle(.white.opacity(0.65))
            Text(step.title).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(step.bullets.enumerated()), id: \.offset) { i, b in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: b.symbol).frame(width: 20).foregroundStyle(.white)
                        Text(b.text).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                    }
                    .opacity(i < revealed ? 1 : 0)
                    .offset(x: i < revealed ? 0 : 24)
                    .animation(.spring(duration: 0.45, bounce: 0.2).delay(Double(i) * 0.12), value: revealed)
                }
            }
        }
        .id(page)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
    }

    /// ← / → page through the tour, whichever control has keyboard focus.
    private func installArrowKeys() {
        guard keyMonitor == nil else { return }
        let page = $page
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.sheetParent != nil,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            switch event.keyCode {
            case 123 where page.wrappedValue > 0:
                withAnimation(.spring(duration: 0.45)) { page.wrappedValue -= 1 }
                return nil
            case 124 where page.wrappedValue < steps.count - 1:
                withAnimation(.spring(duration: 0.45)) { page.wrappedValue += 1 }
                return nil
            default:
                return event
            }
        }
    }

    private func reveal() {
        revealed = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { revealed = step.bullets.count }
    }

    // MARK: art

    @ViewBuilder
    private var artView: some View {
        ZStack {
            switch step.art {
            case .hero:
                HeroLoader()
            case .scan:
                BentoLoader().frame(width: 220, height: 220)
            case .tree, .treemap:
                TreemapArt(tick: artTick).frame(width: 240, height: 220)
            case .safety:
                SafetyArt(tick: artTick).frame(width: 240, height: 220)
            case .clean:
                CleanArt(tick: artTick).frame(width: 240, height: 220)
            case .menuBar:
                MenuBarArt(tick: artTick).frame(width: 260, height: 240)
            case .duplicates:
                DuplicatesArt(tick: artTick).frame(width: 250, height: 230)
            case .whatsNew:
                NavigationArt(tick: artTick).frame(width: 260, height: 240)
            }
        }
        .id(page)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button("Skip") { dismiss() }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
            Spacer()
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(steps) { s in
                        Capsule().fill(.white.opacity(s.id == page ? 0.95 : 0.35))
                            .frame(width: s.id == page ? 22 : 8, height: 8)
                            .animation(.spring(duration: 0.35), value: page)
                    }
                }
                Text("Use ← → to move between pages").font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            HStack(spacing: 8) {
                if page > 0 {
                    Button("Back") { withAnimation(.spring(duration: 0.45)) { page -= 1 } }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
                        .help("Previous page (←)")
                }
                Button(page == steps.count - 1 ? "Get Started" : "Next") {
                    if page == steps.count - 1 { dismiss() } else { withAnimation(.spring(duration: 0.45)) { page += 1 } }
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(Color(red: 0.35, green: 0.25, blue: 0.9))
                .keyboardShortcut(.defaultAction)
                .help(page == steps.count - 1 ? "Close the tour (Return)" : "Next page (→ or Return)")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(.black.opacity(0.15))
    }
}

// MARK: - Art pieces

private struct TreemapArt: View {
    let tick: Int
    private let rects: [(CGRect, Color)] = [
        (CGRect(x: 0, y: 0, width: 0.55, height: 0.6), .yellow), (CGRect(x: 0.57, y: 0, width: 0.43, height: 0.35), .pink),
        (CGRect(x: 0.57, y: 0.37, width: 0.43, height: 0.23), .mint), (CGRect(x: 0, y: 0.62, width: 0.3, height: 0.38), .blue),
        (CGRect(x: 0.32, y: 0.62, width: 0.38, height: 0.38), .purple), (CGRect(x: 0.72, y: 0.62, width: 0.28, height: 0.38), .orange),
    ]
    var body: some View {
        GeometryReader { g in
            ForEach(Array(rects.enumerated()), id: \.offset) { i, r in
                let rect = r.0
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(r.1.opacity(0.85))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: tick % rects.count == i ? 2.5 : 0))
                    .frame(width: rect.width * g.size.width - 4, height: rect.height * g.size.height - 4)
                    .position(x: (rect.midX) * g.size.width, y: rect.midY * g.size.height)
                    .scaleEffect(tick % rects.count == i ? 1.04 : 1)
                    .animation(.easeInOut(duration: 0.4), value: tick)
            }
        }
    }
}

private struct SafetyArt: View {
    let tick: Int
    private let rows: [(String, String, SafetyLevel)] = [
        ("node_modules", "shippingbox", .safe), ("DerivedData", "hammer", .safe), ("Application Support", "folder", .caution),
        ("Photos Library", "photo", .never),
    ]
    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                HStack {
                    Image(systemName: r.1).frame(width: 18)
                    Text(r.0).lineLimit(1)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: r.2.symbol)
                        Text(r.2.short)
                    }
                    .font(.caption.bold()).foregroundStyle(r.2.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(r.2.color.opacity(0.28), in: Capsule())
                    .overlay(Capsule().strokeBorder(r.2.color.opacity(0.6), lineWidth: 0.5))
                    .scaleEffect(tick % rows.count == i ? 1.12 : 1)
                    .animation(.spring(duration: 0.4, bounce: 0.4), value: tick)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(.white)
            }
        }
    }
}

private struct CleanArt: View {
    let tick: Int
    var body: some View {
        let phase = tick % 4   // 0-1: tiles present, 2: shrinking, 3: gone
        VStack(spacing: 14) {
            ZStack {
                BentoTiles(lit: 5)
                    .scaleEffect(phase >= 2 ? 0.2 : 1)
                    .opacity(phase >= 2 ? 0 : 1)
                    .animation(.easeIn(duration: 0.5), value: phase)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 90)).foregroundStyle(.white)
                    .opacity(phase == 3 ? 1 : 0).scaleEffect(phase == 3 ? 1 : 0.5)
                    .animation(.spring(duration: 0.5, bounce: 0.4), value: phase)
            }
            .frame(width: 170, height: 170)
            Text(phase == 3 ? "Freed 23.6 GB" : "node_modules · 23.6 GB")
                .font(.headline).foregroundStyle(.white).contentTransition(.opacity)
        }
    }
}


/// Three identical files slide together, the extra copies get checked and vanish, the freed space appears.
private struct DuplicatesArt: View {
    let tick: Int
    private var phase: Int { tick % 6 }   // 0-1 scattered, 2 grouped, 3 extras checked, 4 extras gone, 5 freed
    private let offsets: [CGSize] = [CGSize(width: -70, height: -60), CGSize(width: 60, height: -20), CGSize(width: -20, height: 60)]

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let gone = phase >= 4 && i > 0
                    VStack(spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.9))
                                .frame(width: 64, height: 80)
                                .overlay(alignment: .topLeading) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        ForEach(0..<5, id: \.self) { l in
                                            Capsule().fill(Color(red: 0.45, green: 0.35, blue: 0.95).opacity(0.35))
                                                .frame(width: l == 4 ? 26 : 44, height: 5)
                                        }
                                    }
                                    .padding(10)
                                }
                            if phase == 3 && i > 0 {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                                    .foregroundStyle(.white, Color(red: 0.93, green: 0.42, blue: 0.42))
                                    .offset(x: 6, y: -6)
                            }
                            if phase >= 4 && i == 0 {
                                Image(systemName: "star.circle.fill").font(.system(size: 18))
                                    .foregroundStyle(.white, Color(red: 0.38, green: 0.78, blue: 0.54))
                                    .offset(x: 6, y: -6)
                            }
                        }
                        Text("IMG_4021.heic").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    }
                    .offset(phase < 2 ? offsets[i] : CGSize(width: CGFloat(i - 1) * 74, height: 0))
                    .scaleEffect(gone ? 0.3 : 1)
                    .opacity(gone ? 0 : 1)
                    .zIndex(Double(3 - i))
                }
            }
            .frame(width: 240, height: 140)
            Text(phase >= 5 ? "Freed 8.2 MB" : phase >= 2 ? "3 copies · 4.1 MB each" : "Scanning for duplicates…")
                .font(.headline).foregroundStyle(.white).contentTransition(.opacity)
        }
        .animation(.spring(duration: 0.6, bounce: 0.25), value: phase)
    }
}

/// Menu bar ring draining to red, the popover appearing, one click cleaning, ring back to green.
private struct MenuBarArt: View {
    let tick: Int
    private var phase: Int { tick % 9 }
    // 0-2 draining, 3 popover appears, 4-5 clean button pulses, 6 cleaned + refilled, 7 checkmark, 8 popover gone
    private var free: Double {
        switch phase { case 0: return 0.48; case 1: return 0.26; case 2, 3, 4, 5: return 0.07; default: return 0.42 }
    }
    private var color: Color {
        free < 0.1 ? Color(red: 0.93, green: 0.42, blue: 0.42)
        : free < 0.3 ? Color(red: 0.96, green: 0.70, blue: 0.34)
        : Color(red: 0.38, green: 0.78, blue: 0.54)
    }
    private var popoverShown: Bool { (3...7).contains(phase) }

    var body: some View {
        VStack(spacing: 0) {
            // Mini menu bar
            HStack(spacing: 14) {
                Spacer()
                ring(size: 18, lineWidth: 3)
                Text(free < 0.1 ? "34 GB" : free < 0.3 ? "129 GB" : "212 GB")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                ForEach(["wifi", "battery.75percent", "magnifyingglass"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 12))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 30)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Popover
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Macintosh HD").font(.caption.bold())
                        Spacer()
                        Text(free < 0.1 ? "Low" : free < 0.3 ? "Getting low" : "Healthy")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(color.opacity(0.3), in: Capsule()).foregroundStyle(color)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(free < 0.1 ? "34 GB" : "208 GB")
                            .font(.system(size: 22, weight: .bold, design: .rounded)).contentTransition(.numericText())
                        Text("free").font(.caption).opacity(0.7)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule().fill(color).frame(width: g.size.width * (1 - free))
                        }
                    }
                    .frame(height: 6)
                    .animation(.spring(duration: 0.6), value: free)

                    if phase >= 6 {
                        Label("Freed 12.3 GB", systemImage: "checkmark.circle.fill")
                            .font(.caption.bold()).foregroundStyle(Color(red: 0.55, green: 0.9, blue: 0.68))
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Text("Clean 12.3 GB (safe items only)")
                            .font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .scaleEffect(phase == 4 || phase == 5 ? 1.06 : 1)
                            .shadow(color: .white.opacity(phase == 4 || phase == 5 ? 0.6 : 0), radius: 10)
                    }
                }
                .padding(12)
                .frame(width: 190)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25)))
                .foregroundStyle(.white)
                .offset(x: 12, y: 10)
                .opacity(popoverShown ? 1 : 0)
                .scaleEffect(popoverShown ? 1 : 0.85, anchor: .top)
                .animation(.spring(duration: 0.45, bounce: 0.25), value: popoverShown)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .animation(.spring(duration: 0.55), value: phase)
    }

    private func ring(size: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.3), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.04, free))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6), value: free)
        }
        .frame(width: size, height: size)
        .scaleEffect(free < 0.1 && phase < 6 && phase % 2 == 0 ? 1.15 : 1)
    }
}

/// A mini Headroom window: the pointer clicks a dashboard tile, the treemap opens, then Back returns to the dashboard.
private struct NavigationArt: View {
    let tick: Int
    private var phase: Int { tick % 7 }   // 0 pointer travels, 1 tile pressed, 2-3 treemap, 4 Back pressed, 5 dashboard again, 6 rest
    private var showsTreemap: Bool { (2...4).contains(phase) }
    private let tileColors: [Color] = [.pink, .mint, .orange, .cyan]

    var body: some View {
        VStack(spacing: 16) {
            window
                .overlay(alignment: .topLeading) {
                    Image(systemName: "cursorarrow").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .scaleEffect(phase == 1 || phase == 4 ? 0.85 : 1)
                        .offset(pointer)
                }
            Text(caption).font(.headline).foregroundStyle(.white).contentTransition(.opacity)
        }
        .animation(.spring(duration: 0.55, bounce: 0.2), value: phase)
    }

    private var pointer: CGSize {
        switch phase {
        case 0: return CGSize(width: 110, height: 150)
        case 1, 2, 3: return CGSize(width: 186, height: 86)    // over the second tile
        case 4, 5: return CGSize(width: 58, height: 6)         // over Back
        default: return CGSize(width: 130, height: 140)
        }
    }

    private var caption: String {
        switch phase {
        case 0, 1: return "Click a tile"
        case 2, 3: return "Its view opens"
        case 4, 5: return "⌘[ goes back"
        default: return "⌘1–⌘7 jump anywhere"
        }
    }

    private var window: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.45)).frame(width: 7, height: 7) }
                Spacer().frame(width: 2)
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                    .padding(3)
                    .background(.white.opacity(phase == 4 ? 0.45 : 0), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .opacity(showsTreemap ? 1 : 0.4)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).opacity(0.4)
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 24)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule().fill(.white.opacity(i == (showsTreemap ? 2 : 0) ? 0.95 : 0.35)).frame(width: 30, height: 5)
                    }
                }
                .padding(10)
                .frame(width: 52, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
                .background(.black.opacity(0.15))
                ZStack {
                    if showsTreemap {
                        TreemapArt(tick: tick).padding(10).transition(.scale(scale: 0.92).combined(with: .opacity))
                    } else {
                        dashboard.transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 240, height: 170)
        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var dashboard: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [.purple.opacity(0.7), .blue.opacity(0.6)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 26)
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { col in tile(row * 2 + col) }
                }
            }
        }
        .padding(10)
    }

    private func tile(_ i: Int) -> some View {
        let pressed = i == 1 && phase == 1
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(pressed ? 0.42 : 0.2))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(pressed ? 0.8 : 0), lineWidth: 1.5))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(tileColors[i]).frame(width: 24, height: 4)
                    Capsule().fill(.white.opacity(0.85)).frame(width: 40, height: 7)
                }
                .padding(8)
            }
            .scaleEffect(pressed ? 0.94 : 1)
    }
}

/// App icon with an orbiting light — reads as "working", not a static picture.
private struct HeroLoader: View {
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle()
                .stroke(AngularGradient(colors: [.clear, .white.opacity(0.9), .clear], center: .center), lineWidth: 6)
                .frame(width: 236, height: 236)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 2.2).repeatForever(autoreverses: false), value: spin)
            Circle().fill(.white).frame(width: 12, height: 12).shadow(color: .white, radius: 8)
                .offset(y: -118)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 2.2).repeatForever(autoreverses: false), value: spin)
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 190, height: 190)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
        }
        .onAppear { spin = true }
    }
}
