import Foundation
import CoreGraphics

/// A single OHLCV bar as delivered by Hyperliquid's `candleSnapshot` REST
/// endpoint and the `candle` WS subscription. The raw wire format keeps every
/// numeric as a stringified decimal; computed `CGFloat` accessors parse those
/// strings once so the chart layer can render without re-parsing per frame.
struct Candle: Codable, Identifiable, Hashable {
    let t: Int64       // open time (ms)
    let T: Int64       // close time (ms)
    let s: String      // symbol
    let i: String      // interval
    let o: String
    let c: String
    let h: String
    let l: String
    let v: String
    let n: Int

    var id: Int64 { t }
    var open:   CGFloat { CGFloat(Double(o) ?? 0) }
    var close:  CGFloat { CGFloat(Double(c) ?? 0) }
    var high:   CGFloat { CGFloat(Double(h) ?? 0) }
    var low:    CGFloat { CGFloat(Double(l) ?? 0) }
    var volume: CGFloat { CGFloat(Double(v) ?? 0) }
    var date:   Date    { Date(timeIntervalSince1970: TimeInterval(t) / 1000) }
    /// Legacy alias retained while the old SwiftUI Charts view is phased out.
    var openTime: Date { date }
}

enum CandleInterval: String, CaseIterable, Identifiable {
    case m1 = "1m"
    case m5 = "5m"
    case m15 = "15m"
    case h1 = "1h"
    case h4 = "4h"
    case d1 = "1d"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .m1: return 60
        case .m5: return 300
        case .m15: return 900
        case .h1: return 3600
        case .h4: return 14400
        case .d1: return 86400
        }
    }
}
