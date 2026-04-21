import XCTest
@testable import HyperliquidApp

final class HyperliquidAppTests: XCTestCase {

    func testMarketDecoding() throws {
        let meta = AssetMeta(name: "BTC", szDecimals: 3, maxLeverage: 50)
        let ctx = AssetContext(
            funding: "0.0001",
            openInterest: "1000",
            prevDayPx: "100000",
            dayNtlVlm: "5000000",
            premium: nil,
            oraclePx: "105000",
            markPx: "105100",
            midPx: "105050",
            impactPxs: nil
        )
        let market = Market(meta: meta, context: ctx)
        XCTAssertEqual(market.name, "BTC")
        XCTAssertEqual(market.markPrice, 105100)
        XCTAssertEqual(market.dayChangePct ?? 0, 0.051, accuracy: 0.001)
    }

    func testL2BookSides() throws {
        let json = """
        {"coin":"BTC","levels":[[{"px":"100","sz":"1","n":1}],[{"px":"101","sz":"2","n":2}]],"time":0}
        """.data(using: .utf8)!
        let book = try JSONDecoder().decode(L2Book.self, from: json)
        XCTAssertEqual(book.bids.first?.price, 100)
        XCTAssertEqual(book.asks.first?.size, 2)
    }

    // Encoded manually from the Python `msgpack.packb({"type":"order","orders":[],"grouping":"na"})`.
    func testMsgPackOrderShape() {
        let value: MsgPackValue = .map([
            ("type", .string("order")),
            ("orders", .array([])),
            ("grouping", .string("na"))
        ])
        let bytes = MsgPack.pack(value)
        // fixmap(3) | fixstr "type" | fixstr "order" | fixstr "orders" | fixarray(0) | fixstr "grouping" | fixstr "na"
        let expected: [UInt8] = [
            0x83,
            0xa4, 0x74, 0x79, 0x70, 0x65,
            0xa5, 0x6f, 0x72, 0x64, 0x65, 0x72,
            0xa6, 0x6f, 0x72, 0x64, 0x65, 0x72, 0x73,
            0x90,
            0xa8, 0x67, 0x72, 0x6f, 0x75, 0x70, 0x69, 0x6e, 0x67,
            0xa2, 0x6e, 0x61
        ]
        XCTAssertEqual(Array(bytes), expected)
    }

    func testFloatToWireStripsZeros() {
        XCTAssertEqual(OrderAction.floatToWire(42.5), "42.5")
        XCTAssertEqual(OrderAction.floatToWire(1.00000000), "1")
        XCTAssertEqual(OrderAction.floatToWire(0.00001234), "0.00001234")
    }
}
