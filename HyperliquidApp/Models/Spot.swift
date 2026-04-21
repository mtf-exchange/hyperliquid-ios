import Foundation

// Spot universe / pair / market / perp-dex types live in Market.swift.
// Spot balances + clearinghouse state, TWAP snapshots, and non-funding ledger
// events live in UserState.swift and History.swift respectively.
// This file only exposes helpers on the PerpDex type so that the synthetic
// "core" dex entry has a consistent display label across views.

extension PerpDex {
    /// Reader-friendly label — falls back to the short name for entries that
    /// don't ship a `full_name`.
    var displayName: String {
        isCore ? "Hyperliquid Core" : (full_name.isEmpty ? name : full_name)
    }
}
