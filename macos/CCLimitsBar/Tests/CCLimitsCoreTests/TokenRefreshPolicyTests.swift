import XCTest
@testable import CCLimitsCore

final class TokenRefreshPolicyTests: XCTestCase {
    private typealias P = TokenRefreshPolicy

    func testБезПричиныНеДёргаем() {
        XCTAssertFalse(P.shouldLaunch(P.State(expired: false)))
    }

    func testВыключенноеНеДёргаем() {
        XCTAssertFalse(P.shouldLaunch(P.State(expired: true, enabled: false)))
    }

    func testПросроченныйВходДёргает() {
        XCTAssertTrue(P.shouldLaunch(P.State(expired: true)))
    }

    func testПокаЗапросИдётВторойНеШлём() {
        XCTAssertFalse(P.shouldLaunch(P.State(expired: true, inFlight: true)))
    }

    func testПаузаМеждуПопыткамиСоблюдается() {
        let now = Date()
        let recent = now.addingTimeInterval(-60)
        XCTAssertFalse(P.shouldLaunch(P.State(expired: true, lastAttempt: recent), now: now),
                       "минуту назад уже пробовали")
        let old = now.addingTimeInterval(-P.retryInterval - 1)
        XCTAssertTrue(P.shouldLaunch(P.State(expired: true, lastAttempt: old), now: now))
    }

    func testСерияНеудачОстанавливаетПопытки() {
        let s = P.State(expired: true, failures: P.maxFailures)
        XCTAssertFalse(P.shouldLaunch(s), "иначе бюджет жжётся в пустоту")
    }

    func testПриговорПоФактуАНеПоКодуВозврата() {
        XCTAssertNil(P.verdict(P.State(expired: true)), "попытки не было - приговаривать нечего")
        XCTAssertEqual(P.verdict(P.State(expired: false, awaitingVerdict: true)), true)
        XCTAssertEqual(P.verdict(P.State(expired: true, awaitingVerdict: true)), false)
    }

    func testПокаЗапросИдётПриговораНет() {
        let s = P.State(expired: false, inFlight: true, awaitingVerdict: true)
        XCTAssertNil(P.verdict(s))
    }
}
