import XCTest
@testable import Headroom

final class TreemapLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)

    private func flat(_ sizes: [Int64]) -> FileNode {
        TestSupport.tree("root") { r in sizes.enumerated().map { TestSupport.file("f\($0)", size: $1, parent: r) } }
    }

    func testTopLevelCellsTileTheBoundsInProportionToSize() {
        let root = flat([600, 250, 100, 40, 10])
        let cells = TreemapLayout.layout(root: root, in: bounds, maxDepth: 4)
        XCTAssertEqual(cells.count, 5)
        let area = bounds.width * bounds.height
        XCTAssertEqual(cells.reduce(0) { $0 + $1.rect.width * $1.rect.height }, area, accuracy: 1)
        for cell in cells {
            XCTAssertTrue(bounds.insetBy(dx: -0.01, dy: -0.01).contains(cell.rect), "\(cell.node.name) escapes the bounds")
            let share = Double(cell.node.allocatedSize) / 1000
            XCTAssertEqual(Double(cell.rect.width * cell.rect.height) / Double(area), share, accuracy: 0.001)
            XCTAssertTrue(cell.isLeaf)
            XCTAssertEqual(cell.depth, 0)
        }
    }

    func testCellsDoNotOverlap() {
        let cells = TreemapLayout.layout(root: flat([50, 40, 30, 20, 10, 5, 5, 3, 2, 1]), in: bounds, maxDepth: 1)
        for (i, a) in cells.enumerated() {
            for b in cells[(i + 1)...] {
                let overlap = a.rect.intersection(b.rect)
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.01, "\(a.node.name) overlaps \(b.node.name)")
            }
        }
    }

    func testSquarifyingKeepsAspectRatiosReasonable() {
        let cells = TreemapLayout.layout(root: flat(Array(repeating: 10, count: 16)), in: bounds, maxDepth: 1)
        for cell in cells {
            let ratio = max(cell.rect.width / cell.rect.height, cell.rect.height / cell.rect.width)
            XCTAssertLessThan(ratio, 3, "equal files should come out close to square")
        }
    }

    func testEmptyAndTinyItemsAreSkipped() {
        XCTAssertTrue(TreemapLayout.layout(root: flat([0, 0]), in: bounds, maxDepth: 4).isEmpty)
        XCTAssertTrue(TreemapLayout.layout(root: flat([10]), in: CGRect(x: 0, y: 0, width: 2, height: 2), maxDepth: 4).isEmpty)
        // One byte in ten billion rounds to less than half a point: dropped, not drawn as a sliver.
        let cells = TreemapLayout.layout(root: flat([10_000_000_000, 1]), in: bounds, maxDepth: 4)
        XCTAssertEqual(cells.map(\.node.name), ["f0"])
    }

    func testFoldersNestUpToMaxDepth() {
        let root = TestSupport.tree("root") { r in [
            TestSupport.tree("a", parent: r) { a in [
                TestSupport.tree("b", parent: a) { b in [TestSupport.file("deep", size: 500, parent: b)] },
                TestSupport.file("side", size: 300, parent: a),
            ] },
            TestSupport.file("top", size: 200, parent: r),
        ] }
        let all = TreemapLayout.layout(root: root, in: bounds, maxDepth: 4)
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.node.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["a", "b", "deep", "side", "top"])
        XCTAssertEqual(byName["a"]?.isLeaf, false)
        XCTAssertEqual(byName["deep"]?.depth, 2)
        let a = try! XCTUnwrap(byName["a"]).rect
        let deep = try! XCTUnwrap(byName["deep"]).rect
        XCTAssertTrue(a.contains(deep))
        XCTAssertGreaterThanOrEqual(deep.minY, a.minY + TreemapLayout.headerHeight, "children sit below the folder's header")

        let shallow = TreemapLayout.layout(root: root, in: bounds, maxDepth: 0)
        XCTAssertEqual(Set(shallow.map(\.node.name)), ["a", "top"])
        XCTAssertTrue(shallow.allSatisfy(\.isLeaf))
    }

    func testPackagesAreNotOpenedUp() {
        let root = TestSupport.tree("root") { r in
            let app = TestSupport.dir("Big.app", package: true, parent: r)
            app.finalize(children: [TestSupport.file("binary", size: 900, parent: app)])
            return [app]
        }
        let cells = TreemapLayout.layout(root: root, in: bounds, maxDepth: 4)
        XCTAssertEqual(cells.map(\.node.name), ["Big.app"])
        XCTAssertTrue(cells[0].isLeaf)
    }

    func testColourModesHaveTitles() {
        XCTAssertEqual(TreemapColorMode.allCases.map(\.title), ["Category", "Age", "Safety"])
        XCTAssertEqual(TreemapColorMode.safety.id, "safety")
    }
}

final class NavigationTests: XCTestCase {
    func testBackAndForwardWalkTheHistory() {
        let nav = Navigation()
        XCTAssertEqual(nav.current.pane, .dashboard)
        XCTAssertFalse(nav.canGoBack)
        nav.go(.treemap)
        nav.go(.largest)
        XCTAssertEqual(nav.back.map(\.pane), [.dashboard, .treemap])

        nav.goBack()
        XCTAssertEqual(nav.current.pane, .treemap)
        XCTAssertTrue(nav.canGoForward)
        nav.goForward()
        XCTAssertEqual(nav.current.pane, .largest)
        XCTAssertFalse(nav.canGoForward)

        nav.goBack()
        nav.go(.cleanup)
        XCTAssertFalse(nav.canGoForward, "a new step drops the forward history")
    }

    func testGoingToTheCurrentPaneIsNotAStep() {
        let nav = Navigation()
        nav.go(.dashboard)
        XCTAssertFalse(nav.canGoBack)
    }

    func testBackAndForwardAtTheEndsDoNothing() {
        let nav = Navigation()
        nav.goBack()
        nav.goForward()
        XCTAssertEqual(nav.current, Navigation.Stop(pane: .dashboard))
    }

    func testCategoryFocusIsRememberedForBack() {
        let nav = Navigation()
        nav.categoryFocus = .video
        nav.go(.categories)
        XCTAssertEqual(nav.current.category, .video)
        XCTAssertNil(nav.categoryFocus, "the focus is used once")
        nav.noteCategory(.images)
        nav.go(.largest)
        nav.goBack()
        XCTAssertEqual(nav.current, Navigation.Stop(pane: .categories, category: .images))

        nav.goForward()
        nav.noteCategory(.audio)
        XCTAssertNil(nav.current.category, "only By Category records a category")
    }

    func testResetClearsHistoryButKeepsThePane() {
        let nav = Navigation()
        nav.go(.tree)
        nav.go(.treemap)
        nav.goBack()
        nav.reset()
        XCTAssertFalse(nav.canGoBack)
        XCTAssertFalse(nav.canGoForward)
        XCTAssertEqual(nav.current.pane, .tree)
    }

    func testEveryPaneHasATitleAndSymbol() {
        for pane in Pane.allCases {
            XCTAssertFalse(pane.title.isEmpty)
            XCTAssertFalse(pane.symbol.isEmpty)
            XCTAssertEqual(pane.id, pane.rawValue)
        }
        XCTAssertEqual(Set(Pane.allCases.map(\.title)).count, Pane.allCases.count)
    }
}
