import Observation

/// What the user has paid for.
///
/// Everything downstream reads ``isUnlocked``, so wiring StoreKit means populating a set of owned
/// product identifiers from `Transaction.currentEntitlements` plus a `Transaction.updates`
/// listener, and testing membership here. Defaults to unlocked so the feature is usable first.
@MainActor
@Observable
final class Entitlements {

    /// Whether custom colours may be rendered onto the wall.
    var isUnlocked = true
}
