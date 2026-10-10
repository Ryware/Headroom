import XCTest
@testable import Headroom

final class ScanLocationTests: XCTestCase {
    private func location(_ path: String, volume: Bool = false, volumeName: String? = nil,
                          displayName: String? = nil) -> ScanLocation {
        ScanLocation(path: path, isVolumeRoot: volume, volumeName: volumeName, displayName: displayName, homePath: "/Users/ann")
    }

    func testRootIsNamedAfterTheStartupDisk() {
        let l = location("/", volume: true, volumeName: "Macintosh HD")
        XCTAssertEqual(l.kind, .startupDisk)
        XCTAssertEqual(l.name, "Macintosh HD")
        XCTAssertEqual(l.detail, "Whole startup disk")
        XCTAssertEqual(l.symbol, "internaldrive")
        XCTAssertEqual(l.phrase, "on Macintosh HD")
    }

    func testRootWithoutVolumeNameStillHasAWord() {
        XCTAssertEqual(location("/", volume: true).name, "Startup Disk")
    }

    func testOtherVolumesUseTheirName() {
        let l = location("/Volumes/Backup", volume: true, volumeName: "Backup")
        XCTAssertEqual(l.kind, .volume)
        XCTAssertEqual(l.name, "Backup")
        XCTAssertEqual(l.phrase, "on Backup")
        XCTAssertEqual(l.symbol, "externaldrive")
    }

    func testHomeFolderIsNamedLikeFinder() {
        let l = location("/Users/ann/")
        XCTAssertEqual(l.kind, .home)
        XCTAssertEqual(l.name, "ann")
        XCTAssertEqual(l.symbol, "house")
        XCTAssertEqual(l.phrase, "in ann")
        XCTAssertEqual(l.detail, "/Users/ann")
    }

    func testFoldersUseFinderDisplayName() {
        let l = location("/Users/ann/Downloads", displayName: "Загрузки")
        XCTAssertEqual(l.kind, .folder)
        XCTAssertEqual(l.name, "Загрузки")
        XCTAssertEqual(l.phrase, "in Загрузки")
    }

    func testRealHomeURLMatchesFinder() {
        let home = NSHomeDirectory()
        let l = ScanLocation(url: URL(fileURLWithPath: home))
        XCTAssertEqual(l.kind, .home)
        XCTAssertEqual(l.name, FileManager.default.displayName(atPath: home))
    }

    func testPlainFolderKeepsItsNameAndPath() {
        let l = location("/Library/Caches")
        XCTAssertEqual(l.kind, .folder)
        XCTAssertEqual(l.name, "Caches")
        XCTAssertEqual(l.detail, "/Library/Caches")
        XCTAssertEqual(l.phrase, "in Caches")
    }

    func testRealRootURL() {
        let l = ScanLocation(url: URL(fileURLWithPath: "/"))
        XCTAssertEqual(l.kind, .startupDisk)
        XCTAssertNotEqual(l.name, "/")
    }
}
