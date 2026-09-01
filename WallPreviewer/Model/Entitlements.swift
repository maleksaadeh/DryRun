import Observation

/// What the user has paid for.
///
/// ## Wiring this to StoreKit
///
/// Everything downstream reads ``isUnlocked`` and nothing else, so the whole purchase story lands
/// inside this one type. To make it real:
///
/// 1. Create a non-consumable product in App Store Connect and note its identifier.
/// 2. Add a `.storekit` configuration file to the scheme so the Simulator can transact.
/// 3. Replace the stored property below with a `Set<String>` of owned product identifiers,
///    populated from `Transaction.currentEntitlements` at launch and kept current by a detached
///    `Transaction.updates` listener — the listener is not optional, it is how a purchase made on
///    another device, or an interrupted one, ever arrives.
/// 4. Have ``isUnlocked`` test membership in that set.
///
/// No caller changes when that happens. The paywall sheet is the only new view, and the one place
/// that needs it is already marked in `ContentView.swatches`.
///
/// It defaults to unlocked rather than locked so the feature is usable and demonstrable before any
/// of the above exists. Flip it to `false` to see the locked path — the swatch row, the form and
/// the selected-colour row all stay live, and only the wall goes unpainted.
@MainActor
@Observable
final class Entitlements {

    /// Whether custom colours may be rendered onto the wall.
    ///
    /// Gates the wall, deliberately, and nothing before it. The user can add a colour, check the
    /// hex and LRV they typed, correct them, and see the chip in the row — everything except the
    /// payoff. Gating the "+" button instead would ask for money before showing that the feature
    /// works at all.
    var isUnlocked = true
}
