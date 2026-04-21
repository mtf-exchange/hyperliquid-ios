import Foundation

struct UserFill: Codable, Identifiable, Hashable {
    let coin: String
    let px: String
    let sz: String
    let side: String
    let time: Int64
    let startPosition: String?
    let dir: String?
    let closedPnl: String?
    let hash: String
    let oid: Int64
    let crossed: Bool?
    let fee: String?
    let tid: Int64
    var id: Int64 { tid }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(time) / 1000) }
    var price: Double { Double(px) ?? 0 }
    var size: Double { Double(sz) ?? 0 }
    var isBuy: Bool { side == "B" }
    var pnl: Double? { closedPnl.flatMap(Double.init) }
    var feeValue: Double? { fee.flatMap(Double.init) }
}

struct UserFunding: Codable, Identifiable, Hashable {
    let time: Int64
    let hash: String
    let delta: FundingDelta
    var id: String { "\(time)-\(delta.coin)" }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(time) / 1000) }
}

struct FundingDelta: Codable, Hashable {
    let type: String
    let coin: String
    let usdc: String
    let szi: String
    let fundingRate: String
    var usdcValue: Double { Double(usdc) ?? 0 }
    var rate: Double { Double(fundingRate) ?? 0 }
}

struct TwapState: Codable, Identifiable, Hashable {
    let coin: String
    let side: String
    let sz: String
    let executedSz: String?
    let reduceOnly: Bool?
    let minutes: Int?

    var id: String { "\(coin)-\(side)-\(sz)" }
    var isBuy: Bool { side == "B" }
    var size: Double { Double(sz) ?? 0 }
    var executedSize: Double { Double(executedSz ?? "0") ?? 0 }
}

struct NonFundingLedgerDelta: Codable, Hashable {
    let type: String
    let usdc: String?
    let coin: String?
    let amount: String?

    var usdcValue: Double { Double(usdc ?? amount ?? "0") ?? 0 }
}

struct NonFundingLedgerEvent: Codable, Identifiable, Hashable {
    let time: Int64
    let hash: String
    let delta: NonFundingLedgerDelta

    var id: String { "\(time)-\(hash)" }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(time) / 1000) }
}
