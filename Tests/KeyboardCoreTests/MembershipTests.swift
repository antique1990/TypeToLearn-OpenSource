import XCTest
@testable import KeyboardCore

final class MembershipTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testAnnualDiscountUsesTwelveMonthlyPayments() throws {
        let discount = try XCTUnwrap(MembershipAnnualDiscount(monthlyPrice: Decimal(string: "1.99")!, yearlyPrice: Decimal(string: "9.99")!))
        XCTAssertEqual(discount.savingsPercent, 58)
        XCTAssertEqual(discount.chineseRate, "4.2")
        let halfPrice = try XCTUnwrap(MembershipAnnualDiscount(monthlyPrice: 10, yearlyPrice: 60))
        XCTAssertEqual(halfPrice.savingsPercent, 50)
        XCTAssertEqual(halfPrice.chineseRate, "5")
    }
    func testAnnualDiscountDoesNotOverstateSavingsOrShowInvalidOffers() {
        XCTAssertNil(MembershipAnnualDiscount(monthlyPrice: 0, yearlyPrice: 10))
        XCTAssertNil(MembershipAnnualDiscount(monthlyPrice: 10, yearlyPrice: 0))
        XCTAssertNil(MembershipAnnualDiscount(monthlyPrice: -1, yearlyPrice: 10))
        XCTAssertNil(MembershipAnnualDiscount(monthlyPrice: .nan, yearlyPrice: 10))
        XCTAssertNil(MembershipAnnualDiscount(monthlyPrice: 10, yearlyPrice: 120))
        XCTAssertNil(MembershipAnnualDiscount(monthlyPrice: 10, yearlyPrice: 121))
        XCTAssertNil(MembershipAnnualDiscount(monthlyPrice: 10, yearlyPrice: Decimal(string: "119.99")!))
        XCTAssertEqual(MembershipAnnualDiscount(monthlyPrice: 10, yearlyPrice: Decimal(string: "60.01")!)?.savingsPercent, 49)
    }
    func testTrialAndSubscriptionExpireAtBoundary() {
        let trial = MembershipGrant(productID: MembershipPlan.monthly.productID, expiration: now.addingTimeInterval(1))
        XCTAssertTrue(trial.isActive(at: now))
        XCTAssertFalse(trial.isActive(at: now.addingTimeInterval(1)))
        XCTAssertFalse(trial.isActive(at: now.addingTimeInterval(2)))
        let annual = MembershipGrant(productID: MembershipPlan.yearly.productID, expiration: now.addingTimeInterval(-1))
        XCTAssertFalse(annual.isActive(at: now))
    }
    func testUnknownRevokedAndMalformedGrantsCannotUnlock() {
        let grants = [
            MembershipGrant(productID: "other.app.lifetime", expiration: nil),
            MembershipGrant(productID: MembershipPlan.monthly.productID, expiration: nil),
            MembershipGrant(productID: MembershipPlan.lifetime.productID, expiration: nil, revoked: true),
            MembershipGrant(productID: MembershipPlan.yearly.productID, expiration: now.addingTimeInterval(100), revoked: true)
        ]
        XCTAssertFalse(MembershipSnapshot(grants: grants, verifiedAt: now).hasAccess(at: now))
        XCTAssertFalse(MembershipSnapshot().hasAccess(at: now))
    }
    func testLifetimeSurvivesExpiredSubscriptionAndRoundTrip() throws {
        let snapshot = MembershipSnapshot(grants: [
            MembershipGrant(productID: MembershipPlan.monthly.productID, expiration: now.addingTimeInterval(-1)),
            MembershipGrant(productID: MembershipPlan.lifetime.productID, expiration: nil)
        ], verifiedAt: now)
        let copy = try JSONDecoder().decode(MembershipSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(copy, snapshot)
        XCTAssertTrue(copy.hasAccess(at: now.addingTimeInterval(10 * 365 * 86400)))
    }
    func testVerifiedPurchaseSuppliesAccessWhileEntitlementRefreshCatchesUp() {
        let purchase = MembershipGrant(productID: MembershipPlan.monthly.productID, expiration: now.addingTimeInterval(300))
        let refreshed = MembershipSnapshot(grants: [], verifiedAt: now, confirmedGrant: purchase)
        XCTAssertTrue(refreshed.hasAccess(at: now))
        let caughtUp = MembershipSnapshot(grants: [purchase], verifiedAt: now, confirmedGrant: purchase)
        XCTAssertEqual(caughtUp.grants, [purchase])
        let expired = MembershipSnapshot(grants: [], verifiedAt: now.addingTimeInterval(300), confirmedGrant: purchase)
        XCTAssertFalse(expired.hasAccess(at: now.addingTimeInterval(300)))
        XCTAssertTrue(expired.grants.isEmpty)
    }
    func testEveryDemoCandidateHasTranslationAcrossLanguagesAndLayouts() {
        for language in KeyboardDemo.supportedLanguageIDs {
            for script in [ChineseScript.simplified, .traditional] {
                for english in [false, true] {
                    for cangjie in [false, true] where !english || !cangjie {
                        for sample in 0..<KeyboardDemo.count {
                            for word in KeyboardDemo.candidates(sample, english: english, script: script, cangjie: cangjie) {
                                XCTAssertFalse(KeyboardDemo.candidateTranslation(word, language: language, english: english, script: script)?.isEmpty ?? true, "\(word) -> \(language)")
                            }
                        }
                    }
                }
            }
        }
    }
}
