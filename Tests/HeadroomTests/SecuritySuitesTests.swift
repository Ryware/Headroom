import XCTest
@testable import Headroom

final class SecuritySuitesTests: XCTestCase {
    func testDetectsProductsByTheirInstallPaths() {
        let present: Set<String> = ["/Library/Bitdefender", "/Applications/AVGAntivirus.app"]
        let found = SecuritySuites.detect(fileExists: { present.contains($0) })
        XCTAssertEqual(Set(found.map(\.id)), ["bitdefender", "avg"])
        XCTAssertTrue(SecuritySuites.detect(fileExists: { _ in false }).isEmpty)
    }

    func testSuspectsAreTheFolderGuardingProductsOrEveryoneWhenNoneIsKnownToGuard() {
        let eset = SecuritySuite.known.first { $0.id == "eset" }!
        let avg = SecuritySuite.known.first { $0.id == "avg" }!
        let bitdefender = SecuritySuite.known.first { $0.id == "bitdefender" }!
        XCTAssertEqual(SecuritySuites.suspects(among: [eset, avg, bitdefender]).map(\.id), ["avg", "bitdefender"],
                       "two shields side by side: the one already allowed is not the one refusing, so both are named")
        XCTAssertEqual(SecuritySuites.suspects(among: [eset]).map(\.id), ["eset"])
        XCTAssertTrue(SecuritySuites.suspects(among: []).isEmpty)
    }

    func testGuardedFoldersMatchThemselvesAndTheirContents() {
        let folders = ["/Users/x/Documents", "/Users/x/Pictures"]
        XCTAssertTrue(SecuritySuites.isGuarded("/Users/x/Documents", folders: folders))
        XCTAssertTrue(SecuritySuites.isGuarded("/Users/x/Documents/git/a/node_modules", folders: folders))
        XCTAssertFalse(SecuritySuites.isGuarded("/Users/x/Documents2/a", folders: folders))
        XCTAssertFalse(SecuritySuites.isGuarded("/Users/x/Library/Caches", folders: folders))
    }

    func testMessagesNameTheProductAndSayWhereToAllowHeadroom() {
        let bitdefender = SecuritySuite.known.first { $0.id == "bitdefender" }!
        let avg = SecuritySuite.known.first { $0.id == "avg" }!
        let m = SecuritySuites.stallMessage(for: [bitdefender])
        XCTAssertTrue(m.contains("Bitdefender's Safe Files"), m)
        XCTAssertTrue(m.contains(bitdefender.howToAllow), m)
        XCTAssertTrue(m.contains("Finder"), m)
        let both = SecuritySuites.stallMessage(for: [avg, bitdefender])
        XCTAssertTrue(both.contains("AVG Antivirus's Ransomware Shield or Bitdefender's Safe Files"), both)
        XCTAssertTrue(both.contains(avg.howToAllow) && both.contains(bitdefender.howToAllow), both)
        let generic = SecuritySuites.stallMessage(for: [])
        XCTAssertTrue(generic.contains("antivirus or ransomware shield"), generic)
        XCTAssertTrue(SecuritySuites.trashBlockedMessage(for: [bitdefender]).contains("Safe Files"))
        XCTAssertTrue(SecuritySuites.warning(for: [avg, bitdefender]).contains("allow Headroom in AVG Antivirus and Bitdefender"))
    }

    func testEveryKnownProductHasDetectionPathsAndInstructions() {
        for s in SecuritySuite.known {
            XCTAssertFalse(s.appPaths.isEmpty, s.id)
            XCTAssertFalse(s.howToAllow.isEmpty, s.id)
            XCTAssertFalse(s.name.isEmpty, s.id)
        }
        XCTAssertEqual(Set(SecuritySuite.known.map(\.id)).count, SecuritySuite.known.count, "ids must be unique")
    }
}
