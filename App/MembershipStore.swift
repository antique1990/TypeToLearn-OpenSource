import Combine
import Foundation
import KeyboardCore
import StoreKit

@MainActor
final class MembershipStore: ObservableObject {
    enum Notice { case unavailable, purchaseFailed, pending, restored, nothingToRestore, verificationFailed, sharingFailed }
    @Published private(set) var products: [Product] = []
    @Published private(set) var snapshot = SharedMembership.load()
    @Published private(set) var loading = false
    @Published private(set) var purchasing = false
    @Published private(set) var checkingEntitlements = true
    @Published private(set) var monthlyTrialEligible = false
    @Published var notice: Notice?
    private var updates: Task<Void, Never>?
    private var entitlementTask: Task<Bool, Never>?
    private var entitlementRequest = 0

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled, let self else { return }
                guard case .verified(let transaction) = result,
                      MembershipPlan(productID: transaction.productID) != nil else { continue }
                if await self.reconcileEntitlements(including: transaction) {
                    await transaction.finish()
                }
            }
        }
    }
    deinit { updates?.cancel() }
    var hasAccess: Bool { snapshot.hasAccess() }
    func product(_ plan: MembershipPlan) -> Product? { products.first { $0.id == plan.productID } }
    var annualDiscount: MembershipAnnualDiscount? {
        guard let monthly = product(.monthly), let yearly = product(.yearly),
              monthly.priceFormatStyle.currencyCode == yearly.priceFormatStyle.currencyCode else { return nil }
        return MembershipAnnualDiscount(monthlyPrice: monthly.price, yearlyPrice: yearly.price)
    }

    func loadProducts() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            products = try await Product.products(for: MembershipPlan.allCases.map(\.productID))
            if products.count != MembershipPlan.allCases.count { notice = .unavailable }
            else if notice == .unavailable { notice = nil }
            if let info = product(.monthly)?.subscription,
               let offer = info.introductoryOffer, offer.paymentMode == .freeTrial,
               offer.period.unit == .day, offer.period.value == 3 {
                monthlyTrialEligible = await info.isEligibleForIntroOffer
            } else { monthlyTrialEligible = false }
        } catch { notice = .unavailable }
    }

    func refreshEntitlements() async {
        _ = await reconcileEntitlements()
    }

    private func reconcileEntitlements(including transaction: Transaction? = nil) async -> Bool {
        let previous = entitlementTask
        entitlementRequest += 1
        let request = entitlementRequest
        checkingEntitlements = true
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return false }
            defer {
                if self.entitlementRequest == request {
                    self.entitlementTask = nil
                    self.checkingEntitlements = false
                }
            }
            return await self.readEntitlements(including: transaction)
        }
        entitlementTask = task
        return await task.value
    }

    private func activeGrant(for transaction: Transaction, graceUntil: Date? = nil) -> MembershipGrant? {
        guard transaction.revocationDate == nil, !transaction.isUpgraded else { return nil }
        let grant = MembershipGrant(productID: transaction.productID, expiration: graceUntil ?? transaction.expirationDate)
        return grant.isActive(at: Date()) ? grant : nil
    }

    private func readEntitlements(including transaction: Transaction?) async -> Bool {
        let confirmed = transaction.flatMap { activeGrant(for: $0) }
        if let confirmed {
            // Deliver Apple's verified purchase before any further StoreKit calls.
            _ = publish(MembershipSnapshot(grants: snapshot.grants, verifiedAt: Date(), confirmedGrant: confirmed))
        }
        var grants: [MembershipGrant] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  MembershipPlan(productID: transaction.productID) != nil else { continue }
            if let grant = activeGrant(for: transaction) {
                grants.append(grant)
            } else if transaction.revocationDate == nil, !transaction.isUpgraded,
                      let status = await transaction.subscriptionStatus,
                      let grant = gracePeriodGrant(for: status, transaction: transaction) {
                grants.append(grant)
            }
        }
        var checkedGroups = Set<String>()
        for product in products {
            guard let subscription = product.subscription,
                  !checkedGroups.contains(subscription.subscriptionGroupID),
                  let statuses = try? await subscription.status else { continue }
            checkedGroups.insert(subscription.subscriptionGroupID)
            for status in statuses {
                guard case .verified(let transaction) = status.transaction else { continue }
                let grant: MembershipGrant?
                switch status.state {
                case .subscribed:
                    grant = activeGrant(for: transaction)
                case .inGracePeriod:
                    grant = gracePeriodGrant(for: status, transaction: transaction)
                default:
                    continue
                }
                if let grant, !grants.contains(grant) { grants.append(grant) }
            }
        }
        // A refresh may start before currentEntitlements includes this purchase.
        return publish(MembershipSnapshot(grants: grants, verifiedAt: Date(), confirmedGrant: confirmed))
    }

    private func gracePeriodGrant(for status: Product.SubscriptionInfo.Status, transaction: Transaction) -> MembershipGrant? {
        guard status.state == .inGracePeriod, case .verified(let current) = status.transaction,
              current.id == transaction.id, case .verified(let renewal) = status.renewalInfo,
              let until = renewal.gracePeriodExpirationDate else { return nil }
        return activeGrant(for: current, graceUntil: until)
    }

    private func publish(_ snapshot: MembershipSnapshot) -> Bool {
        self.snapshot = snapshot
        do {
            try SharedMembership.save(snapshot)
            if notice == .sharingFailed { notice = nil }
            return true
        } catch {
            notice = .sharingFailed
            return false
        }
    }

    func purchase(_ plan: MembershipPlan) async {
        guard !purchasing, !checkingEntitlements, !hasAccess else { return }
        guard let product = product(plan) else { notice = .unavailable; return }
        purchasing = true; notice = nil
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else { notice = .verificationFailed; return }
                if await reconcileEntitlements(including: transaction) {
                    await transaction.finish()
                }
            case .pending: notice = .pending
            case .userCancelled: break
            @unknown default: notice = .purchaseFailed
            }
        } catch { notice = .purchaseFailed }
    }

    func restore() async {
        guard !purchasing else { return }
        purchasing = true; notice = nil
        defer { purchasing = false }
        do {
            try await AppStore.sync()
            guard await reconcileEntitlements() else { return }
            notice = hasAccess ? .restored : .nothingToRestore
        } catch { notice = .purchaseFailed }
    }
}
