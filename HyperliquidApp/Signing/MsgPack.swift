import Foundation

/// A tiny MessagePack encoder covering exactly the types Hyperliquid's
/// `action_hash` needs: nil, bool, int, double, string, byte array, array,
/// and **ordered** string-keyed map. The Python SDK uses `msgpack.packb(action)`
/// which packs Python dicts in insertion order, so we deliberately model maps
/// as `[(String, MsgPackValue)]` rather than Swift `Dictionary` (whose
/// iteration order is undefined).
///
/// Ints follow msgpack's "smallest encoding" rule (positive/negative fixint,
/// then uint/int 8/16/32/64), matching `msgpack.packb(use_bin_type=True)` behavior.
indirect enum MsgPackValue {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MsgPackValue])
    case map([(String, MsgPackValue)])
}

enum MsgPack {
    static func pack(_ value: MsgPackValue) -> Data {
        var out = Data()
        encode(value, into: &out)
        return out
    }

    // MARK: -

    private static func encode(_ value: MsgPackValue, into out: inout Data) {
        switch value {
        case .nil:
            out.append(0xc0)

        case .bool(let b):
            out.append(b ? 0xc3 : 0xc2)

        case .int(let i):
            encodeInt(i, into: &out)

        case .uint(let u):
            encodeUInt(u, into: &out)

        case .double(let d):
            out.append(0xcb)
            append(UInt64(bitPattern: Int64(d.bitPattern)).bigEndianBytes, to: &out)

        case .string(let s):
            let bytes = Data(s.utf8)
            let c = bytes.count
            switch c {
            case 0..<32:      out.append(UInt8(0xa0 | c))
            case 0..<(1<<8):  out.append(0xd9); out.append(UInt8(c))
            case 0..<(1<<16): out.append(0xda); append(UInt16(c).bigEndianBytes, to: &out)
            default:          out.append(0xdb); append(UInt32(c).bigEndianBytes, to: &out)
            }
            out.append(bytes)

        case .binary(let data):
            let c = data.count
            switch c {
            case 0..<(1<<8):  out.append(0xc4); out.append(UInt8(c))
            case 0..<(1<<16): out.append(0xc5); append(UInt16(c).bigEndianBytes, to: &out)
            default:          out.append(0xc6); append(UInt32(c).bigEndianBytes, to: &out)
            }
            out.append(data)

        case .array(let items):
            let c = items.count
            switch c {
            case 0..<16:      out.append(UInt8(0x90 | c))
            case 0..<(1<<16): out.append(0xdc); append(UInt16(c).bigEndianBytes, to: &out)
            default:          out.append(0xdd); append(UInt32(c).bigEndianBytes, to: &out)
            }
            for item in items { encode(item, into: &out) }

        case .map(let pairs):
            let c = pairs.count
            switch c {
            case 0..<16:      out.append(UInt8(0x80 | c))
            case 0..<(1<<16): out.append(0xde); append(UInt16(c).bigEndianBytes, to: &out)
            default:          out.append(0xdf); append(UInt32(c).bigEndianBytes, to: &out)
            }
            for (k, v) in pairs {
                encode(.string(k), into: &out)
                encode(v, into: &out)
            }
        }
    }

    private static func encodeInt(_ i: Int64, into out: inout Data) {
        if i >= 0 { encodeUInt(UInt64(i), into: &out); return }
        switch i {
        case -32..<0:
            out.append(UInt8(bitPattern: Int8(i)))
        case Int64(Int8.min)..<(-32):
            out.append(0xd0); out.append(UInt8(bitPattern: Int8(i)))
        case Int64(Int16.min)..<Int64(Int8.min):
            out.append(0xd1); append(UInt16(bitPattern: Int16(i)).bigEndianBytes, to: &out)
        case Int64(Int32.min)..<Int64(Int16.min):
            out.append(0xd2); append(UInt32(bitPattern: Int32(i)).bigEndianBytes, to: &out)
        default:
            out.append(0xd3); append(UInt64(bitPattern: i).bigEndianBytes, to: &out)
        }
    }

    private static func encodeUInt(_ u: UInt64, into out: inout Data) {
        switch u {
        case 0..<128:         out.append(UInt8(u))                 // positive fixint
        case 0..<(1<<8):      out.append(0xcc); out.append(UInt8(u))
        case 0..<(1<<16):     out.append(0xcd); append(UInt16(u).bigEndianBytes, to: &out)
        case 0..<(1<<32):     out.append(0xce); append(UInt32(u).bigEndianBytes, to: &out)
        default:              out.append(0xcf); append(u.bigEndianBytes, to: &out)
        }
    }

    private static func append<S: Sequence>(_ bytes: S, to data: inout Data) where S.Element == UInt8 {
        data.append(contentsOf: bytes)
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian, Array.init)
    }
}
