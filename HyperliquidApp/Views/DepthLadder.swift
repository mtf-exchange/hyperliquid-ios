import Foundation

/// Precomputed cumulative-depth view of an L2 book. The orderbook UI reads
/// `cumulative` for the background heat bars so the widest bar corresponds
/// to the full-depth tail, giving traders a meaningful sense of where resting
/// liquidity sits.
struct DepthLadder {
    struct Entry {
        let price: Double
        let size: Double
        let cumulative: Double
    }

    let bids: [Entry]
    let asks: [Entry]
    let maxCumulative: Double

    init(book: L2Book, depth: Int) {
        let topBids = book.bids.prefix(depth)
        let topAsks = book.asks.prefix(depth)

        var runningBid = 0.0
        let bids: [Entry] = topBids.map { level in
            runningBid += level.size
            return Entry(price: level.price, size: level.size, cumulative: runningBid)
        }

        var runningAsk = 0.0
        // Build asks deepest-first so the ladder reads top-to-bottom as the
        // spread closes — this matches every Hyperliquid-style orderbook UI.
        let askEntries: [Entry] = topAsks.map { level in
            runningAsk += level.size
            return Entry(price: level.price, size: level.size, cumulative: runningAsk)
        }

        self.bids = bids
        self.asks = askEntries.reversed()
        self.maxCumulative = max(runningBid, runningAsk, 1)
    }
}
