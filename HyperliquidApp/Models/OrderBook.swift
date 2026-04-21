import Foundation

struct L2Level: Codable, Hashable {
    let px: String
    let sz: String
    let n: Int

    var price: Double { Double(px) ?? 0 }
    var size: Double { Double(sz) ?? 0 }
}

struct L2Book: Codable {
    let coin: String
    let levels: [[L2Level]]
    let time: Int64

    var bids: [L2Level] { levels.indices.contains(0) ? levels[0] : [] }
    var asks: [L2Level] { levels.indices.contains(1) ? levels[1] : [] }
}

struct Trade: Codable, Identifiable, Hashable {
    let coin: String
    let side: String
    let px: String
    let sz: String
    let time: Int64
    let hash: String
    let tid: Int64

    var id: Int64 { tid }
    var price: Double { Double(px) ?? 0 }
    var size: Double { Double(sz) ?? 0 }
    var isBuy: Bool { side == "B" }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(time) / 1000) }
}
