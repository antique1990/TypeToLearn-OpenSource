import Foundation

public struct MembershipAnnualDiscount: Equatable, Sendable {
    public let savingsPercent: Int
    public var chineseRate: String {
        let percent = 100 - savingsPercent
        return percent.isMultiple(of: 10) ? "\(percent / 10)" : "\(percent / 10).\(percent % 10)"
    }

    public init?(monthlyPrice: Decimal, yearlyPrice: Decimal) {
        guard !monthlyPrice.isNaN, !yearlyPrice.isNaN,
              monthlyPrice > 0, yearlyPrice > 0 else { return nil }
        let annualMonthlyPrice = monthlyPrice * 12
        guard yearlyPrice < annualMonthlyPrice else { return nil }
        var percent = yearlyPrice / annualMonthlyPrice * 100
        var rounded = Decimal()
        // Round the payable percentage up so the badge never overstates savings.
        NSDecimalRound(&rounded, &percent, 0, .up)
        let savings = 100 - NSDecimalNumber(decimal: rounded).intValue
        guard savings > 0 else { return nil }
        savingsPercent = savings
    }
}

public enum MembershipPlan: String, CaseIterable, Codable, Identifiable, Sendable {
    case monthly, yearly, lifetime
    public var id: String { rawValue }
    public var productID: String {
        switch self {
        case .monthly: "typetolearn_monthly_plan"
        case .yearly: "typetolearn_yearly_plan"
        case .lifetime: "typetolearn_lifetimepro"
        }
    }
    public init?(productID: String) {
        guard let plan = Self.allCases.first(where: { $0.productID == productID }) else { return nil }
        self = plan
    }
}

public struct MembershipGrant: Codable, Equatable, Sendable {
    public let productID: String
    public let expiration: Date?
    public let revoked: Bool
    public init(productID: String, expiration: Date?, revoked: Bool = false) {
        self.productID = productID; self.expiration = expiration; self.revoked = revoked
    }
    public func isActive(at date: Date) -> Bool {
        guard !revoked, let plan = MembershipPlan(productID: productID) else { return false }
        if plan == .lifetime { return expiration == nil }
        return expiration.map { $0 > date } ?? false
    }
}

public struct MembershipSnapshot: Codable, Equatable, Sendable {
    public var grants: [MembershipGrant]
    public var verifiedAt: Date
    public init(grants: [MembershipGrant] = [], verifiedAt: Date = .distantPast, confirmedGrant: MembershipGrant? = nil) {
        self.grants = grants
        self.verifiedAt = verifiedAt
        if let confirmedGrant, confirmedGrant.isActive(at: verifiedAt), !grants.contains(confirmedGrant) {
            self.grants.append(confirmedGrant)
        }
    }
    public func hasAccess(at date: Date = Date()) -> Bool { grants.contains { $0.isActive(at: date) } }
}
