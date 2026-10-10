import XCTest
@testable import Headroom

final class DeleterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestSupport.makeTempDir("delete") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func permanentDelete(_ nodes: [FileNode]) async -> DeleteResult {
        await Deleter(mode: .permanent, counters: DeleteCounters()).delete(nodes)
    }

    func testPermanentDeleteRemovesWholeTree() async throws {
        let victim = dir.appendingPathComponent("victim")
        try TestSupport.write(victim.appendingPathComponent("a.bin"), bytes: 1_000)
        try TestSupport.write(victim.appendingPathComponent("x/b.bin"), bytes: 2_000)
        try TestSupport.write(victim.appendingPathComponent("x/y/z/c.bin"), bytes: 3_000)
        let keeper = try TestSupport.write(dir.appendingPathComponent("keep.txt"), bytes: 10)

        let (root, _) = try await TestSupport.scan(dir)
        let node = try XCTUnwrap(root.children.first { $0.name == "victim" })
        let result = await permanentDelete([node])

        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(result.removedFiles, 3)
        XCTAssertEqual(result.removedDirectories, 4)   // victim, x, y, z
        XCTAssertGreaterThan(result.freedBytes, 0)
    }

    func testPermanentDeleteOfSingleFile() async throws {
        let f = try TestSupport.write(dir.appendingPathComponent("lonely.bin"), bytes: 5_000)
        let (root, _) = try await TestSupport.scan(dir)
        let node = try XCTUnwrap(root.children.first)
        let result = await permanentDelete([node])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testPermanentDeleteLeavesNoHiddenStashBehind() async throws {
        try TestSupport.write(dir.appendingPathComponent("gone/a.bin"), bytes: 100)
        let (root, _) = try await TestSupport.scan(dir)
        _ = await permanentDelete([try XCTUnwrap(root.children.first)])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(leftovers.isEmpty, "unexpected leftovers: \(leftovers)")
    }

    func testPermanentDeleteOfSeveralRootsAtOnce() async throws {
        for name in ["one", "two", "three"] {
            try TestSupport.write(dir.appendingPathComponent("\(name)/f.bin"), bytes: 100)
        }
        let (root, _) = try await TestSupport.scan(dir)
        let result = await permanentDelete(root.children)
        XCTAssertEqual(result.removedFiles, 3)
        XCTAssertEqual(result.removedDirectories, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testMissingTargetReportsErrorInsteadOfCrashing() async throws {
        try TestSupport.write(dir.appendingPathComponent("temp/a.bin"), bytes: 100)
        let (root, _) = try await TestSupport.scan(dir)
        let node = try XCTUnwrap(root.children.first)
        try FileManager.default.removeItem(at: node.url)     // vanish behind the scanner's back
        let result = await permanentDelete([node])
        XCTAssertEqual(result.removedFiles, 0)
    }

    func testCountersReachTheTotal() async throws {
        try TestSupport.write(dir.appendingPathComponent("t/a.bin"), bytes: 100)
        try TestSupport.write(dir.appendingPathComponent("t/b.bin"), bytes: 100)
        let (root, _) = try await TestSupport.scan(dir)
        let counters = DeleteCounters()
        _ = await Deleter(mode: .permanent, counters: counters).delete(root.children)
        let s = counters.snapshot
        XCTAssertEqual(s.done, s.total)
        XCTAssertGreaterThan(s.total, 0)
    }

    func testLockedFileIsUnlockedAndDeleted() async throws {
        let victim = dir.appendingPathComponent("locked")
        let f = try TestSupport.write(victim.appendingPathComponent("immutable.bin"), bytes: 100)
        XCTAssertEqual(lchflags(f.path, UInt32(UF_IMMUTABLE)), 0, String(cString: strerror(errno)))
        defer { _ = lchflags(f.path, 0) }

        let (root, _) = try await TestSupport.scan(dir)
        let node = try XCTUnwrap(root.children.first { $0.name == "locked" })
        let result = await permanentDelete([node])

        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    func testControlAbortsAfterConsecutiveSlowRefusals() {
        let fast = Deleter.DeleteControl(slowThreshold: 1_000_000)   // 1 ms
        for _ in 0..<20 { XCTAssertFalse(fast.timed { false }) }     // instant refusals: not a stall
        XCTAssertFalse(fast.aborted, "fast failures (missing files, permissions) must not abort")

        let held = Deleter.DeleteControl(slowThreshold: 1_000_000)
        for _ in 0..<Deleter.DeleteControl.refusalsBeforeAbort {
            XCTAssertFalse(held.aborted)
            _ = held.timed { usleep(3_000); return false }
        }
        XCTAssertTrue(held.stalled, "refusals that each took longer than the threshold mean something is holding every unlink")

        // A security product that scans slowly but allows the deletes: successes keep resetting the streak.
        let scanned = Deleter.DeleteControl(slowThreshold: 1_000_000)
        for _ in 0..<30 {
            _ = scanned.timed { usleep(3_000); return false }
            _ = scanned.timed { true }
        }
        XCTAssertFalse(scanned.aborted)

        // ...but once it flips to refusing everything, we stop promptly despite the earlier successes.
        for _ in 0..<Deleter.DeleteControl.refusalsBeforeAbort { _ = scanned.timed { usleep(3_000); return false } }
        XCTAssertTrue(scanned.stalled)
    }

    func testDecisiveProbeStallsOnOneHeldPermissionRefusal() {
        let held = Deleter.DeleteControl(slowThreshold: 1_000_000)
        XCTAssertFalse(held.timed(decisive: true) { usleep(3_000); errno = EPERM; return false })
        XCTAssertTrue(held.stalled, "one held EPERM on the pre-flight probe is enough to stop")

        let fast = Deleter.DeleteControl(slowThreshold: 1_000_000)
        _ = fast.timed(decisive: true) { errno = EPERM; return false }
        XCTAssertFalse(fast.stalled, "an instant refusal is a normal permission error")

        let io = Deleter.DeleteControl(slowThreshold: 1_000_000)
        _ = io.timed(decisive: true) { usleep(3_000); errno = EIO; return false }
        XCTAssertFalse(io.stalled, "a slow I/O error is a volume problem, not a security product")

        let allowed = Deleter.DeleteControl(slowThreshold: 1_000_000)
        XCTAssertTrue(allowed.timed(decisive: true) { usleep(3_000); return true })
        XCTAssertFalse(allowed.stalled, "held but allowed: a slow scanner, keep going")
    }

    func testResultCarriesRootsForRevealInFinder() async throws {
        let victim = dir.appendingPathComponent("victim")
        try TestSupport.write(victim.appendingPathComponent("a.bin"), bytes: 10)
        let (root, _) = try await TestSupport.scan(dir)
        let node = try XCTUnwrap(root.children.first { $0.name == "victim" })
        let result = await permanentDelete([node])
        XCTAssertEqual(result.roots, [victim.path])
        XCTAssertFalse(result.stalled)
        XCTAssertTrue(result.blockedBy.isEmpty)
    }

    func testCancelStopsTheDeleteAndReportsIt() async throws {
        let victim = dir.appendingPathComponent("victim")
        for i in 0..<20 { try TestSupport.write(victim.appendingPathComponent("f\(i).bin"), bytes: 100) }
        let (root, _) = try await TestSupport.scan(dir)
        let node = try XCTUnwrap(root.children.first { $0.name == "victim" })

        let counters = DeleteCounters()
        var deleter = Deleter(mode: .permanent, counters: counters)
        deleter.control.cancel()                       // cancelled before it starts: nothing may be removed
        let result = await deleter.delete([node])

        XCTAssertEqual(result.removedFiles, 0)
        XCTAssertEqual(result.errors.first?.message, Deleter.cancelMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path), "the stash must be renamed back")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: victim.path).count, 20)
        let s = counters.snapshot
        XCTAssertEqual(s.done, s.total, "progress must still reach the total so the sheet can close")
    }

    func testDeleteModeLabels() {
        XCTAssertEqual(DeleteMode.allCases.count, 2)
        XCTAssertTrue(DeleteMode.trash.actionLabel.contains("Trash"))
        XCTAssertTrue(DeleteMode.permanent.actionLabel.contains("Permanently"))
        XCTAssertNotEqual(DeleteMode.trash.symbol, DeleteMode.permanent.symbol)
        XCTAssertNotEqual(DeleteMode.trash.shortNote, DeleteMode.permanent.shortNote)
        XCTAssertEqual(DeleteMode(rawValue: "trash"), .trash)
    }

    func testTrashFailureExplanationsNameTheRealCause() {
        func cocoa(_ code: Int32) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
        }
        // EPERM after a multi-second hold is a ransomware shield; the same errno at once is a privacy folder.
        XCTAssertEqual(Deleter.explainTrashFailure(cocoa(EPERM), path: "/x", held: true), Deleter.trashBlockedMessage)
        XCTAssertEqual(Deleter.explainTrashFailure(cocoa(EPERM), path: "/x", held: false), Deleter.trashPrivacyMessage)
        XCTAssertEqual(Deleter.explainTrashFailure(cocoa(EACCES), path: "/x", held: true), Deleter.trashOwnerMessage)
        let other = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [NSLocalizedDescriptionKey: "gone"])
        XCTAssertEqual(Deleter.explainTrashFailure(other, path: "/x", held: false), "gone")
        XCTAssertEqual(Deleter.explainTrashFailure(nil, path: "/x", held: false), "Could not move to Trash")
        XCTAssertEqual(Deleter.posixCode(of: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))), ENOENT)
        XCTAssertNil(Deleter.posixCode(of: other))
    }
}
