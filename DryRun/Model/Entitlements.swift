import Observation
import StoreKit

/// What the user has paid for.
///
/// One auto-renewable subscription gates custom colours; the built-in catalogue is always free.
/// Ownership lives with the Apple Account, so there is nothing to persist here.
@MainActor
@Observable
final class Entitlements {

    static let annualID = "com.MAS.dryrunpaint.pro.annual"

    /// Whether custom colours may be rendered onto the wall.
    private(set) var isUnlocked = false

    private(set) var product: Product?

    /// False once the introductory offer has been used on this Apple Account.
    private(set) var offersTrial = false

    /// True while a purchase or restore is in flight, to keep the buttons from re-firing.
    private(set) var isWorking = false

    private(set) var failure: String?

    private var listener: Task<Void, Never>?

    init() {
        // Started before the first refresh so a purchase made on another device is not missed.
        listener = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.absorb(update)
            }
        }
        Task { await refresh() }
    }

    // MARK: - Loading

    /// Fetches the product and the trial eligibility behind the paywall's copy.
    func load() async {
        do {
            product = try await Product.products(for: [Self.annualID]).first
            if let subscription = product?.subscription {
                offersTrial = await subscription.isEligibleForIntroOffer
            }
        } catch {
            failure = "Couldn't reach the App Store."
        }
    }

    /// Re-reads what the Apple Account owns. Expired subscriptions are simply absent.
    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.annualID, transaction.revocationDate == nil {
                owned = true
            }
        }
        isUnlocked = owned
    }

    // MARK: - Buying

    func purchase() async {
        guard let product, !isWorking else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                await absorb(verification)
            case .pending:
                // Ask To Buy: the parent approves later and `Transaction.updates` delivers it.
                failure = "Waiting on approval. You'll be unlocked once it goes through."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Required by App Store review for anything restorable.
    func restore() async {
        guard !isWorking else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }

        do {
            try await AppStore.sync()
        } catch {
            failure = "Couldn't restore. Check you're signed in to the App Store."
        }
        await refresh()
        if !isUnlocked { failure = "No subscription found on this Apple Account." }
    }

    private func absorb(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        await refresh()
    }

    // MARK: - Copy

    /// e.g. "3 days free, then $79.99/year", falling back to the plain price.
    var priceLine: String {
        guard let product else { return "" }
        let renewal = "\(product.displayPrice)/year"
        guard offersTrial,
              let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return renewal }
        return "\(Self.describe(offer.period)) free, then \(renewal)"
    }

    private static func describe(_ period: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch period.unit {
        case .day:   unit = "day"
        case .week:  unit = "week"
        case .month: unit = "month"
        case .year:  unit = "year"
        @unknown default: unit = "period"
        }
        return "\(period.value) \(unit)\(period.value == 1 ? "" : "s")"
    }
}
