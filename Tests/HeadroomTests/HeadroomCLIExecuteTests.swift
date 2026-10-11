import XCTest
@testable import Headroom

/// `HeadroomCLI.execute`: the exit code for each kind of command line. Output goes to stdout and
/// stderr as it would in a shell; the tests only check the code.
final class HeadroomCLIExecuteTests: XCTestCase {
    func testHelpAndVersionSucceed() async {
        for argv in [[], ["help"], ["--help"], ["-h"], ["help", "duplicates"], ["--version"], ["scan", "--help"], ["trash", "-h"]] {
            let code = await HeadroomCLI.execute(argv)
            XCTAssertEqual(code, 0, argv.joined(separator: " "))
        }
    }

    func testUnknownCommandsFail() async {
        let typo = await HeadroomCLI.execute(["scna"])
        XCTAssertEqual(typo, 1)
        let helpTypo = await HeadroomCLI.execute(["help", "scna"])
        XCTAssertEqual(helpTypo, 1)
    }

    func testBadOptionsFailBeforeCallingTheTool() async {
        let unknown = await HeadroomCLI.execute(["largest", "/", "--nope"])
        XCTAssertEqual(unknown, 1)
        let missingValue = await HeadroomCLI.execute(["largest", "/", "--limit"])
        XCTAssertEqual(missingValue, 1)
    }

    func testTrashNeedsYes() async throws {
        let dir = try TestSupport.makeTempDir("cli-trash")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try TestSupport.write(dir.appendingPathComponent("keep.txt"), bytes: 10)
        let code = await HeadroomCLI.execute(["trash", file.path])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "nothing moves without --yes")
    }

    func testReadOnlyCommandsReachTheTools() async throws {
        let dir = try TestSupport.makeTempDir("cli-call")
        defer { try? FileManager.default.removeItem(at: dir) }
        try TestSupport.write(dir.appendingPathComponent("a.bin"), bytes: 4_096)
        let explain = await HeadroomCLI.execute(["explain", dir.path])
        XCTAssertEqual(explain, 0)
        let status = await HeadroomCLI.execute(["status"])
        XCTAssertEqual(status, 0)
    }

    func testToolErrorsBecomeExitCodeOne() async {
        let code = await HeadroomCLI.execute(["list", "/definitely/not/here/\(UUID().uuidString)"])
        XCTAssertEqual(code, 1)
    }

    func testHelpListsOptionsWithTheirValueKinds() throws {
        let text = HeadroomCLI.help(for: "duplicates", try XCTUnwrap(HeadroomCLI.tool(named: "duplicates")))
        XCTAssertTrue(text.contains("--min-size-mb <n>"))
        XCTAssertTrue(text.contains("--refresh "))
        let largest = HeadroomCLI.help(for: "largest", try XCTUnwrap(HeadroomCLI.tool(named: "largest")))
        XCTAssertTrue(largest.contains("--category <"))
        let trash = HeadroomCLI.help(for: "trash", try XCTUnwrap(HeadroomCLI.tool(named: "trash")))
        XCTAssertTrue(trash.contains("<path>..."))
        XCTAssertTrue(trash.contains("--yes"))
        let state = HeadroomCLI.help(for: "state", try XCTUnwrap(HeadroomCLI.tool(named: "state")))
        XCTAssertFalse(state.contains("Options:"))
    }

    func testBooleanOptionsAcceptExplicitValues() throws {
        let tool = try XCTUnwrap(HeadroomCLI.tool(named: "duplicates"))
        XCTAssertEqual(try HeadroomCLI.arguments(for: tool, ["--refresh=no"])["refresh"] as? Bool, false)
        XCTAssertEqual(try HeadroomCLI.arguments(for: tool, ["--refresh=yes"])["refresh"] as? Bool, true)
        XCTAssertThrowsError(try HeadroomCLI.arguments(for: tool, ["--min-size-mb", "big"]))
    }
}

final class FreeSpaceDeltaTests: XCTestCase {
    private func history(_ hoursAndGB: [(Double, Int64)]) -> [FreeSpaceSample] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return hoursAndGB.map { FreeSpaceSample(t: start.addingTimeInterval($0.0 * 3600), free: $0.1 << 30) }
    }

    func testNeedsAtLeastHalfTheWindow() {
        XCTAssertNil(DiskMonitor.delta(in: [], hours: 24))
        XCTAssertNil(DiskMonitor.delta(in: history([(0, 100), (11, 90)]), hours: 24))
        XCTAssertNotNil(DiskMonitor.delta(in: history([(0, 100), (12, 90)]), hours: 24))
    }

    func testComparesWithTheSampleClosestToTheWindowStart() {
        let h = history([(0, 120), (23, 100), (30, 110), (47, 95)])
        XCTAssertEqual(DiskMonitor.delta(in: h, hours: 24), (95 - 100) << 30)
        XCTAssertEqual(DiskMonitor.delta(in: h, hours: 48), (95 - 120) << 30)
    }
}
