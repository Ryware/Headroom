import XCTest
@testable import Headroom

final class SafetyKBTests: XCTestCase {
    private var home: String { NSHomeDirectory() }

    private func node(_ path: String, directory: Bool = true, parent: FileNode? = nil) -> FileNode {
        let url = URL(fileURLWithPath: path, isDirectory: directory)
        return FileNode(url: url, name: url.lastPathComponent, isDirectory: directory, isSymlink: false, isPackage: false,
                        allocatedSize: 1, logicalSize: 1, modified: nil, category: nil, parent: parent)
    }

    func testLevelsAreOrderedBySeverity() {
        XCTAssertLessThan(SafetyLevel.safe, .usuallySafe)
        XCTAssertLessThan(SafetyLevel.usuallySafe, .caution)
        XCTAssertLessThan(SafetyLevel.caution, .never)
        XCTAssertEqual(SafetyLevel.allCases.count, 5)
    }

    func testEveryLevelHasDisplayStrings() {
        for l in SafetyLevel.allCases {
            XCTAssertFalse(l.short.isEmpty)
            XCTAssertFalse(l.symbol.isEmpty)
        }
    }

    func testHomeRelativeRules() {
        XCTAssertEqual(SafetyKB.info(for: node("\(home)/Library/Caches")).level, .safe)
        XCTAssertEqual(SafetyKB.info(for: node("\(home)/Library/Developer/Xcode/DerivedData")).level, .safe)
        XCTAssertEqual(SafetyKB.info(for: node("\(home)/Library/Mail")).level, .never)
        XCTAssertEqual(SafetyKB.info(for: node("\(home)/Library/Keychains")).level, .never)
        XCTAssertEqual(SafetyKB.info(for: node("\(home)/Library/Application Support")).level, .caution)
        XCTAssertEqual(SafetyKB.info(for: node("\(home)/.Trash")).level, .safe)
    }

    func testSourceReportsMatchedRule() {
        XCTAssertEqual(SafetyKB.info(for: node("\(home)/Library/Caches")).source, "~/Library/Caches")
    }

    func testFolderNameRules() {
        XCTAssertEqual(SafetyKB.info(for: node("/work/app/node_modules")).level, .safe)
        XCTAssertEqual(SafetyKB.info(for: node("/work/app/Pods")).level, .safe)
        XCTAssertEqual(SafetyKB.info(for: node("/work/app/.git")).level, .never)
    }

    func testSystemFoldersAreNever() {
        XCTAssertEqual(SafetyKB.info(for: node("/System")).level, .never)
        XCTAssertEqual(SafetyKB.info(for: node("/usr")).level, .never)
    }

    func testFileExtensionRule() {
        XCTAssertEqual(SafetyKB.info(for: node("/x/backup.zip", directory: false)).level, .usuallySafe)
    }

    func testFilesInheritFromKnownAncestor() {
        let caches = node("\(home)/Library/Caches")
        let app = node("\(home)/Library/Caches/com.example.app", parent: caches)
        let file = node("\(home)/Library/Caches/com.example.app/blob", directory: false, parent: app)
        let info = SafetyKB.info(for: file)
        XCTAssertEqual(info.level, .safe)
        XCTAssertTrue(info.what.hasPrefix("Inside "))

        let support = node("\(home)/Library/Application Support")
        let inner = node("\(home)/Library/Application Support/Foo/data", directory: false, parent: support)
        XCTAssertEqual(SafetyKB.info(for: inner).level, .caution)
    }

    func testUnknownItemsStayUnknown() {
        let info = SafetyKB.info(for: node("/nowhere/at-all/mystery-folder-\(UUID().uuidString)"))
        XCTAssertEqual(info.level, .unknown)
        XCTAssertFalse(info.advice.isEmpty)
    }

    func testInheritedInfoNamesTheMatchedRule() {
        let caches = node("\(home)/Library/Caches")
        let file = node("\(home)/Library/Caches/blob", directory: false, parent: caches)
        let info = SafetyKB.info(for: file)
        XCTAssertEqual(info.source, "~/Library/Caches")
        XCTAssertTrue(info.what.hasPrefix("Inside ~/Library/Caches — "))
    }

    func testLevelAgreesWithInfo() {
        let library = node("\(home)/Library")
        let support = node("\(home)/Library/Application Support", parent: library)
        let app = node("\(home)/Library/Application Support/Foo", parent: support)
        let modules = node("/work/app/node_modules")
        let bundle = FileNode(url: URL(fileURLWithPath: "/Applications/Foo.app", isDirectory: true), name: "Foo.app",
                              isDirectory: true, isSymlink: false, isPackage: true, allocatedSize: 1, logicalSize: 1,
                              modified: nil, category: nil, parent: nil)
        let nodes = [
            library, support, app, modules, bundle,
            node("\(home)/Library/Application Support/Foo/db.sqlite", directory: false, parent: app),
            node("/work/app/node_modules/x/index.js", directory: false, parent: modules),
            node("/System"), node("/x/backup.zip", directory: false), node("/x/notes.txt", directory: false),
            node("/nowhere/mystery"),
        ]
        for n in nodes {
            XCTAssertEqual(SafetyKB.level(for: n), SafetyKB.info(for: n).level, n.path)
        }
    }
}
