import AppKit
import SwiftUI
import XCTest
@testable import Headroom

/// Smoke tests for the SwiftUI and AppKit views: each one is hosted in a real window with sample
/// data, laid out and drawn. They catch crashes, layout traps and force-unwraps on real data
/// rather than checking pixels.
@MainActor
final class ViewRenderTests: XCTestCase {
    private var dir: URL!
    private var savedRecents: [String]?

    override func setUp() async throws {
        _ = NSApplication.shared            // views read NSApp (icon, windows)
        dir = try TestSupport.makeTempDir("views")
        savedRecents = UserDefaults.standard.stringArray(forKey: "recentScans")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        if let savedRecents { UserDefaults.standard.set(savedRecents, forKey: "recentScans") }
        else { UserDefaults.standard.removeObject(forKey: "recentScans") }
    }

    // MARK: Helpers

    /// A scanned state over a small tree with a duplicate pair, a dependency folder and a cache.
    private func scannedState() async throws -> AppState {
        try TestSupport.write(dir.appendingPathComponent("Photos/beach.jpg"), bytes: 1_300_000)
        try TestSupport.write(dir.appendingPathComponent("Photos/copy of beach.jpg"), bytes: 1_300_000)
        try TestSupport.write(dir.appendingPathComponent("Movies/clip.mov"), bytes: 900_000)
        try TestSupport.write(dir.appendingPathComponent("Docs/report.pdf"), bytes: 40_000)
        try TestSupport.write(dir.appendingPathComponent("Docs/notes.txt"), bytes: 2_000)
        try TestSupport.write(dir.appendingPathComponent("proj/node_modules/lib/index.js"), bytes: 120_000)
        try TestSupport.write(dir.appendingPathComponent("proj/src/main.swift"), bytes: 5_000)
        try TestSupport.write(dir.appendingPathComponent("Library/Caches/app/blob.cache"), bytes: 80_000)
        try TestSupport.write(dir.appendingPathComponent("archive.zip"), bytes: 500_000)

        let state = AppState()
        state.scan(dir)
        let root = await state.waitForScan()
        XCTAssertNotNil(root)
        _ = await state.findDuplicatesAndWait()
        return state
    }

    /// Hosts `view` in an offscreen window, lets SwiftUI settle, and draws it into a bitmap.
    @discardableResult
    private func render<V: View>(_ view: V, state: AppState? = nil,
                                 size: CGSize = CGSize(width: 1100, height: 760),
                                 settle: TimeInterval = 0.02) -> NSWindow {
        let host: NSView
        if let state { host = NSHostingView(rootView: view.environmentObject(state)) }
        else { host = NSHostingView(rootView: view) }
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        pump(settle)
        draw(host)
        return window
    }

    private func draw(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("no bitmap for \(type(of: view))")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Main window panes

    func testContentViewRendersEveryPane() async throws {
        let state = try await scannedState()
        let window = render(ContentView(), state: state, settle: 0.1)
        defer { window.close() }
        XCTAssertNotNil(window.contentView)
    }

    func testDashboardRenders() async throws {
        let state = try await scannedState()
        render(DashboardView(pane: .constant(.dashboard), categoryFocus: .constant(nil)), state: state)
    }

    func testTreeAndOutlineRender() async throws {
        let state = try await scannedState()
        render(TreeView(), state: state)
    }

    func testTreemapRendersInEveryColourMode() async throws {
        let state = try await scannedState()
        render(TreemapView(), state: state, settle: 0.05)
    }

    func testCategoriesRender() async throws {
        let state = try await scannedState()
        render(CategoriesView(), state: state)
    }

    func testLargestFilesRender() async throws {
        let state = try await scannedState()
        render(LargestFilesView(), state: state)
    }

    func testDuplicatesRender() async throws {
        let state = try await scannedState()
        XCTAssertFalse(state.duplicates?.groups.isEmpty ?? true)
        render(DuplicatesView(), state: state)
    }

    func testCleanupRenders() async throws {
        let state = try await scannedState()
        render(CleanupView(), state: state)
    }

    func testInspectorRendersForFileFolderAndNothing() async throws {
        let state = try await scannedState()
        let root = try XCTUnwrap(state.root)
        render(InspectorView(), state: state, size: CGSize(width: 300, height: 700))
        let file = try XCTUnwrap(state.largest.first)
        state.selection = [file.id]
        render(InspectorView(), state: state, size: CGSize(width: 300, height: 700))
        state.selection = [root.id, file.id]
        render(InspectorView(), state: state, size: CGSize(width: 300, height: 700))
        state.selection = []
        render(InspectorView(), state: state, size: CGSize(width: 300, height: 700))
    }

    func testStatusBarAndDeleteSheetRender() async throws {
        let state = try await scannedState()
        render(StatusBar(showsSelection: true), state: state, size: CGSize(width: 900, height: 30))
        state.deleting = DeleteProgress()
        render(DeleteProgressSheet(), state: state, size: CGSize(width: 420, height: 200))
    }

    // MARK: Standalone screens

    func testWelcomeRendersWithAndWithoutRecents() async throws {
        let state = AppState()
        render(WelcomeView(), state: state)
        _ = try await scannedState()
        render(WelcomeView(), state: AppState())
    }

    func testIntroRendersEveryPage() {
        for page in 0..<IntroView.pageCount {
            render(IntroView(page: page), size: CGSize(width: 900, height: 620))
        }
    }

    func testSettingsRender() {
        render(SettingsView(), state: AppState(), size: CGSize(width: 520, height: 420))
    }

    func testMenuBarPanelAndLabelRender() async throws {
        let state = try await scannedState()
        DiskMonitor.shared.refresh()
        render(MenuBarPanel(), state: state, size: CGSize(width: 340, height: 560))
        render(MenuBarLabel(showText: true), size: CGSize(width: 120, height: 22))
        render(MenuBarLabel(showText: false), size: CGSize(width: 40, height: 22))
        let now = Date()
        let samples = (0..<24).map { FreeSpaceSample(t: now.addingTimeInterval(Double($0) * 3600), free: Int64(100 + $0 % 5) << 30) }
        render(FreeSpaceChart(samples: samples), size: CGSize(width: 300, height: 80))
        render(FreeSpaceChart(samples: []), size: CGSize(width: 300, height: 80))
    }

    func testDeleteToastRendersEveryOutcome() {
        var ok = DeleteResult()
        ok.removedFiles = 3; ok.freedBytes = 5 << 20; ok.roots = ["/tmp/a"]
        var failed = ok
        failed.errors = [(path: "/tmp/a", message: "Operation not permitted")]
        var stalled = failed
        stalled.stalled = true
        // One window each: stacked in one window, their material and shadows take seconds to draw.
        for result in [ok, failed, stalled] {
            for mode in [DeleteMode.trash, .permanent] {
                render(DeleteToast(result: result, mode: mode, dismiss: {}), size: CGSize(width: 520, height: 160))
            }
        }
    }

    func testSmallComponentsRender() {
        let badges = VStack {
            SizeBar(fraction: 0.4, label: "40%")
            ForEach(SafetyLevel.allCases, id: \.self) { level in
                let info = SafetyInfo(level: level, what: "What", advice: "Advice")
                HStack { SafetyBadge(info: info); SafetyBadge(info: info, compact: true) }
            }
        }
        render(badges, size: CGSize(width: 240, height: 200))
    }
}
