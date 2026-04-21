import Foundation
import SwiftUI

enum Formatters {
    /// Hyperliquid's price display rule (matches the web UI):
    ///   - prices are rendered with **5 significant figures**
    ///   - but with no more than `MAX_DECIMALS - szDecimals` decimal places
    ///     (MAX_DECIMALS is 6 for perps, 8 for spot) — passed as `maxDecimals`
    ///   - integer part never gets truncated, so a $105,432 BTC shows as
    ///     "105,432" even though that's 6 sig figs
    /// Pass `maxDecimals: nil` to skip the decimal cap.
    ///
    /// Examples (sigFigs = 5):
    ///   105432   → 105,432
    ///    75123.4 → 75,123
    ///     2309.7 → 2,309.7
    ///       85.132 → 85.132
    ///        0.1234 → 0.12340
    ///        0.00032 → 0.00032000
    static func price(_ value: Double?, maxDecimals: Int? = nil, sigFigs: Int = 5) -> String {
        guard let value, value.isFinite else { return "—" }
        if value == 0 { return "0" }
        let abs = Swift.abs(value)
        // Magnitude of the leading digit: 1 for values in [1, 10), 2 for
        // [10, 100), 0 for [0.1, 1), -1 for [0.01, 0.1), etc.
        let magnitude = Int(floor(log10(abs))) + 1

        // Significant-figure rule: sigFigs total, integer part never shrinks.
        var decimals = max(0, sigFigs - magnitude)
        if let cap = maxDecimals {
            decimals = min(decimals, cap)
        }

        return decimalNF(minFraction: decimals, maxFraction: decimals, grouping: true)
            .string(from: NSNumber(value: value)) ?? "—"
    }

    /// USD amount. Always two decimals, grouping separators on.
    static func usd(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        return nf.string(from: NSNumber(value: value)) ?? "—"
    }

    /// Percent with explicit sign and 2 decimals (e.g. "+1.23%" / "-0.08%").
    /// Pass a proportion (`0.0123` → "+1.23%"), not an already-scaled value.
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let pct = value * 100
        return String(format: "%+.2f%%", pct)
    }

    /// K / M / B abbreviations on USD amounts for tight UI slots.
    static func compactUSD(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let magnitude = Swift.abs(value)
        let sign = value < 0 ? "-" : ""
        switch magnitude {
        case 1_000_000_000...: return "\(sign)$\(fmt(magnitude / 1_000_000_000))B"
        case 1_000_000...:     return "\(sign)$\(fmt(magnitude / 1_000_000))M"
        case 1_000...:         return "\(sign)$\(fmt(magnitude / 1_000))K"
        default:               return usd(value)
        }
    }

    /// Non-currency compact — used for sizes, volumes-in-units. Drops the `$`.
    static func compact(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let magnitude = Swift.abs(value)
        let sign = value < 0 ? "-" : ""
        switch magnitude {
        case 1_000_000_000...: return "\(sign)\(fmt(magnitude / 1_000_000_000))B"
        case 1_000_000...:     return "\(sign)\(fmt(magnitude / 1_000_000))M"
        case 1_000...:         return "\(sign)\(fmt(magnitude / 1_000))K"
        default:               return size(value, decimals: 4)
        }
    }

    static func size(_ value: Double?, decimals: Int) -> String {
        guard let value, value.isFinite else { return "—" }
        return decimalNF(minFraction: 0, maxFraction: decimals, grouping: false)
            .string(from: NSNumber(value: value)) ?? "—"
    }

    /// `0x1234…abcd` — six leading hex + four trailing. Returns the original
    /// string untouched if it's already short.
    static func truncatedAddress(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }

    // MARK: - Privates

    private static func decimalNF(minFraction: Int, maxFraction: Int, grouping: Bool) -> NumberFormatter {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = minFraction
        nf.maximumFractionDigits = maxFraction
        nf.usesGroupingSeparator = grouping
        return nf
    }

    private static func fmt(_ v: Double) -> String {
        v >= 100 ? String(format: "%.1f", v) : String(format: "%.2f", v)
    }
}

// MARK: - Brand colors

/// Hyperliquid uses teal for positive deltas and a hot-pink red for negative,
/// matching the reference screens. Centralising this keeps every row, chip,
/// and button in sync.
extension Color {
    static let brandUp   = Color(red: 0.15, green: 0.86, blue: 0.73)   // ≈ #26DBBA
    static let brandDown = Color(red: 1.00, green: 0.35, blue: 0.45)   // ≈ #FF597E
    static let cardBg    = Color(white: 0.1).opacity(0.6)

    static func delta(_ value: Double?) -> Color {
        guard let value, value.isFinite else { return .secondary }
        if value > 0 { return .brandUp }
        if value < 0 { return .brandDown }
        return .secondary
    }
}
