import Foundation
import Compression

// MARK: - Apogee Glue IPC protocol (reverse-engineered, see docs/protocol-notes.md)

enum VTSType: UInt8 {
    case getEntireTree = 1
    case setTree = 2
    case setProperty = 3
    case deleteItem = 4
    case setEntireTree = 6
    case command = 7
    case meterData = 8
    case setIndexedPaths = 9
    case childOrderChanged = 10
}

struct VTSRecord {
    let type: UInt8       // VTSType.rawValue
    let flag: Bool
    let data: Data
}

enum GlueProtocol {

    static let juceMagic: UInt32 = 0xF2B49E2C
    static let candidatePorts: [UInt16] = [53435, 61367, 4677, 24110, 36218, 18140, 6414]

    // MARK: checksum fold

    private static func s8(_ x: UInt32) -> Int32 {
        Int32(truncatingIfNeeded: x)  // sign of low byte via Int8 cast below
    }

    /// The F() transform (verified against 2754 captured frames).
    static func F(_ x: UInt32) -> UInt8 {
        var t: UInt32 = (x << 9)
        if Int8(truncatingIfNeeded: x) < 0 { t ^= 0x700 }
        for _ in 0..<6 {
            let prev = Int16(truncatingIfNeeded: t)
            t = (t << 1) & 0xFFFF_FFFF
            if prev < 0 { t ^= 0x700 }
        }
        let last = Int16(truncatingIfNeeded: t)
        var u: UInt32 = t >> 7
        if last < 0 { u ^= 7 }
        return UInt8(truncatingIfNeeded: u)
    }

    static func fold(_ buf: [UInt8], seed: UInt8 = 0) -> UInt8 {
        var key: UInt8 = seed
        for b in buf {
            key = F(UInt32(b ^ key))
        }
        return key
    }

    // MARK: record encode/decode

    static func encode(_ record: VTSRecord) -> Data {
        let size = record.data.count
        let mask: UInt8
        let sizeLen: Int
        if size < 0x100 { mask = 0x00; sizeLen = 1 }
        else if size < 0x10000 { mask = 0x40; sizeLen = 2 }
        else { mask = 0x80; sizeLen = 4 }

        let b0: UInt8 = (record.type & 0x1F) | (record.flag ? 0x20 : 0) | mask
        var sizeBytes = [UInt8](repeating: 0, count: sizeLen)
        var s = UInt32(size)
        for i in 0..<sizeLen { sizeBytes[i] = UInt8(truncatingIfNeeded: s); s >>= 8 }

        var head = [b0] + sizeBytes
        let keybyte = fold(head)
        head.append(keybyte)
        head.append(contentsOf: record.data)
        let chk = fold(head)
        head.append(chk)
        return Data(head)
    }

    struct ParsedRecord {
        let type: UInt8
        let flag: Bool
        let data: Data
        let checksumOK: Bool
    }

    /// Decode one record from `data` starting at offset 0. Returns record + bytes consumed.
    static func decodeOne(_ data: Data) -> (ParsedRecord, Int)? {
        guard data.count >= 3 else { return nil }
        let b0 = data[data.startIndex]
        let type = b0 & 0x1F
        let flag = (b0 >> 5) & 1 == 1
        let mask = b0 & 0xC0
        let sizeLen: Int
        switch mask {
        case 0x00: sizeLen = 1
        case 0x40: sizeLen = 2
        case 0x80: sizeLen = 4
        default: return nil
        }
        guard data.count >= 2 + sizeLen else { return nil }
        var size: UInt32 = 0
        for i in stride(from: sizeLen - 1, through: 0, by: -1) {
            size = (size << 8) | UInt32(data[data.startIndex + 1 + i])
        }
        let total = 1 + sizeLen + 1 + Int(size) + 1
        guard data.count >= total else { return nil }

        var head = [UInt8]()
        head.reserveCapacity(total)
        for i in 0..<(1 + sizeLen + 1) { head.append(data[data.startIndex + i]) }
        let keybyte = head.removeLast()
        // recompute keybyte to validate
        let expectKey = fold([UInt8](data.prefix(1 + sizeLen)))
        var body = [UInt8]()
        for i in (1 + sizeLen + 1)..<(total - 1) { body.append(data[data.startIndex + i]) }
        let chk = data[data.startIndex + total - 1]
        let expectChk = fold(head + [keybyte] + body)

        return (ParsedRecord(type: type,
                             flag: flag,
                             data: Data(body),
                             checksumOK: expectKey == keybyte && expectChk == chk), total)
    }

    // MARK: JUCE frame

    static func wrapJuce(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 8)
        out.appendLE(juceMagic)
        out.appendLE(UInt32(payload.count))
        out.append(payload)
        return out
    }

    static func unwrapJuce(_ data: Data) -> [Data] {
        var frames = [Data]()
        var idx = data.startIndex
        while data.distance(from: idx, to: data.endIndex) >= 8 {
            let magic: UInt32 = data.readLE(at: idx)
            guard magic == juceMagic else {
                idx = data.index(after: idx)
                continue
            }
            let frameLen: UInt32 = data.readLE(at: data.index(idx, offsetBy: 4))
            let len = Int(frameLen)
            let bodyStart = data.index(idx, offsetBy: 8)
            guard len <= 64 * 1024 * 1024,
                  data.distance(from: bodyStart, to: data.endIndex) >= len else { break }
            let bodyEnd = data.index(bodyStart, offsetBy: len)
            frames.append(data.subdata(in: bodyStart..<bodyEnd))
            idx = bodyEnd
        }
        return frames
    }

    // MARK: setProperty payloads

    enum VarTag: UInt8 {
        case int32 = 1
        case int64 = 2
        case bool = 3
        case double = 4
        case string = 5
    }

    static func setPropertyData(id: [UInt8], tag: VarTag, value: Data) -> Data {
        var d = Data()
        d.append(tag.rawValue)
        d.append(contentsOf: id)
        d.append(value)
        return d
    }
}

// MARK: - Data helpers

extension Data {
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }

    func readLE<T: FixedWidthInteger>(at index: Data.Index) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size {
            v = (v << 8) | T(self[index + MemoryLayout<T>.size - 1 - i])
        }
        return v
    }
}

// MARK: - JUCE ValueTree binary stream parser

final class JuceStreamReader {
    private let d: [UInt8]
    private var p = 0

    init(_ data: Data) {
        d = [UInt8](data)
    }

    var bytesLeft: Int { d.count - p }

    private func byte() throws -> UInt8 {
        guard p < d.count else { throw NSError(domain: "JuceStream", code: 1) }
        defer { p += 1 }
        return d[p]
    }

    private func read(_ n: Int) throws -> [UInt8] {
        guard p + n <= d.count else { throw NSError(domain: "JuceStream", code: 2) }
        defer { p += n }
        return Array(d[p..<(p + n)])
    }

    /// JUCE compressed int: byte0 = (count | 0x80*negative), then count LE bytes.
    func cint() throws -> Int {
        let b = try byte()
        let n = Int(b & 0x7F)
        guard n <= 4 else { throw NSError(domain: "JuceStream", code: 3) }
        let bytes = try read(n)
        var mag: UInt32 = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            mag = (mag << 8) | UInt32(bytes[i])
        }
        return (b & 0x80) != 0 ? -Int(mag) : Int(mag)
    }

    func string() throws -> String {
        var out = [UInt8]()
        while true {
            let b = try byte()
            if b == 0 { break }
            out.append(b)
        }
        return String(decoding: out, as: UTF8.self)
    }

    func double() throws -> Double {
        let bytes = try read(8)
        var v: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) { v = (v << 8) | UInt64(bytes[i]) }
        return Double(bitPattern: v)
    }

    func int32() throws -> Int32 {
        let bytes = try read(4)
        var v: UInt32 = 0
        for i in stride(from: 3, through: 0, by: -1) { v = (v << 8) | UInt32(bytes[i]) }
        return Int32(bitPattern: v)
    }

    func juceVar() throws -> Any? {
        let n = try cint()
        guard n > 0 else { return nil }
        let tag = try byte()
        switch tag {
        case 1: return try int32()
        case 6:
            let bytes = try read(8)
            var v: UInt64 = 0
            for i in stride(from: 7, through: 0, by: -1) { v = (v << 8) | UInt64(bytes[i]) }
            return Int64(bitPattern: v)
        case 2: return true
        case 3: return false
        case 4: return try double()
        case 5:
            let s = try read(n - 1)
            return String(decoding: s, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
        case 8: return Data(try read(n - 1))
        case 7:
            let count = try cint()
            var arr = [Any?]()
            for _ in 0..<count { arr.append(try juceVar()) }
            return arr
        case 9: return "undefined"
        default:
            _ = try read(max(0, n - 1))
            return nil
        }
    }

    func tree() throws -> [String: Any]? {
        let type = try string()
        guard !type.isEmpty else { return nil }
        var node: [String: Any] = ["type": type]
        var props = [String: Any?]()
        let nprops = try cint()
        for _ in 0..<nprops {
            let name = try string()
            props[name] = try juceVar()
        }
        node["props"] = props.mapValues { $0 ?? NSNull() }
        var children = [[String: Any]]()
        let nch = try cint()
        for _ in 0..<nch {
            if let c = try tree() {
                children.append(c)
            }
        }
        node["children"] = children
        return node
    }

    static func decompress(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let first = data[data.startIndex]
        let second = data[data.index(after: data.startIndex)]
        var payload = data
        if first == 0x1F && second == 0x8B {
            // gzip: strip 10-byte header
            payload = data.dropFirst(10)
        } else if first == 0x78 {
            // zlib: strip 2-byte header
            payload = data.dropFirst(2)
        }
        return payload.inflatedRaw()
    }
}

extension Data {
    /// Inflate a raw DEFLATE stream (Apple's Compression framework).
    func inflatedRaw() -> Data? {
        var out = Data()
        let result = withUnsafeBytes { (inPtr: UnsafeRawBufferPointer) -> Bool in
            guard let src = inPtr.baseAddress, inPtr.count > 0 else { return false }
            var bufferSize = 1 << 18
            for _ in 0..<16 {  // grow if needed
                let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { dst.deallocate() }
                let written = compression_decode_buffer(dst, bufferSize, src, inPtr.count, nil, COMPRESSION_ZLIB)
                if written == 0 { return out.isEmpty ? false : true }
                out.append(dst, count: written)
                if written < bufferSize { return true }
                bufferSize *= 2
            }
            return false
        }
        return result ? out : nil
    }
}
