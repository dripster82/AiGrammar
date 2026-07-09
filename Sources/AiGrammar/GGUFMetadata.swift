import Foundation

/// The `general.*` metadata we care about, read straight from a `.gguf` file's header. All optional
/// — a field is only set if the file declared it.
struct GGUFInfo {
    var architecture: String?
    var name: String?
    var sizeLabel: String?
    var organization: String?
    var fileType: Int?
    var paramCount: Int?
}

/// Reads GGUF header metadata. GGUF layout: magic "GGUF" (u32), version (u32), tensor_count (u64),
/// kv_count (u64), then the key/value metadata block. We only decode the `general.*` keys.
///
/// The tricky bit: `general.file_type` (the quant) can sit AFTER the giant tokenizer arrays — several
/// MB into the file — so we can't just read a small prefix. For local files we parse via a seekable
/// `FileHandle` and SKIP past big arrays (no loading); for a remote model we parse whatever range was
/// downloaded (best-effort — quant only if it fell inside the range).
enum GGUFMetadata {
    /// Parse a local `.gguf` file (seekable → reaches file_type regardless of tokenizer size).
    static func parse(fileAt path: String) -> GGUFInfo? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        var src = FileSource(handle: handle)
        return parse(&src)
    }

    /// Parse an in-memory buffer (a partial remote download). Bounded by the buffer.
    static func parse(_ data: Data) -> GGUFInfo? {
        var src = DataSource(bytes: [UInt8](data))
        return parse(&src)
    }

    private static func parse<S: GGUFByteSource>(_ s: inout S) -> GGUFInfo? {
        guard let magic = s.u32(), magic == 0x4655_4747 else { return nil }   // "GGUF"
        _ = s.u32()                       // version
        _ = s.u64i()                      // tensor_count
        guard let kvCount = s.u64i() else { return GGUFInfo() }

        var info = GGUFInfo()
        var seen = 0
        while seen < kvCount {
            guard let key = s.str() else { break }
            seen += 1
            guard let vtype = s.u32() else { break }
            guard let value = s.value(type: vtype) else { break }   // couldn't skip/read → stop
            switch key {
            case "general.architecture":    info.architecture = value.string
            case "general.name":            info.name = value.string
            case "general.size_label":      info.sizeLabel = value.string
            case "general.organization":    info.organization = value.string
            case "general.file_type":       info.fileType = value.int
            case "general.parameter_count": info.paramCount = value.int
            default: break
            }
            if info.architecture != nil && info.fileType != nil && info.name != nil { break }
        }
        return info
    }

    /// Compose the subtitle: "[org] · [size] · [arch] · [quant]".
    static func detailString(_ info: GGUFInfo) -> String {
        var parts: [String] = []
        if let o = info.organization, !o.isEmpty { parts.append(o) }
        if let s = info.sizeLabel, !s.isEmpty { parts.append(s) }
        else if let p = info.paramCount, p > 0 { parts.append(formatParams(p)) }
        if let a = info.architecture, !a.isEmpty { parts.append(a) }
        if let ft = info.fileType, let q = fileTypeName(ft) { parts.append(q) }
        return parts.joined(separator: " · ")
    }

    private static func formatParams(_ n: Int) -> String {
        let b = Double(n)
        if b >= 1e9 { return String(format: "%.1fB", b / 1e9) }
        if b >= 1e6 { return String(format: "%.0fM", b / 1e6) }
        return "\(n)"
    }

    /// LLAMA_FTYPE integer → human quant label.
    static func fileTypeName(_ ftype: Int) -> String? {
        switch ftype {
        case 0: return "F32"
        case 1: return "F16"
        case 2: return "Q4_0"
        case 3: return "Q4_1"
        case 7: return "Q8_0"
        case 8: return "Q5_0"
        case 9: return "Q5_1"
        case 10: return "Q2_K"
        case 11: return "Q3_K_S"
        case 12: return "Q3_K_M"
        case 13: return "Q3_K_L"
        case 14: return "Q4_K_S"
        case 15: return "Q4_K_M"
        case 16: return "Q5_K_S"
        case 17: return "Q5_K_M"
        case 18: return "Q6_K"
        case 19: return "IQ2_XXS"
        case 20: return "IQ2_XS"
        case 23: return "IQ3_XXS"
        case 25: return "IQ1_S"
        case 28: return "IQ3_S"
        case 29: return "IQ2_S"
        case 34: return "BF16"
        case 36: return "TQ1_0"
        case 37: return "TQ2_0"
        default: return nil
        }
    }
}

// MARK: - Byte source (seekable file, or bounded buffer) + typed reads

/// A decoded GGUF scalar, surfaced as whatever the caller needs.
private struct GGUFValue { var string: String?; var int: Int? }

private protocol GGUFByteSource {
    /// Read exactly `n` bytes, advancing; nil if fewer are available.
    mutating func read(_ n: Int) -> [UInt8]?
    /// Advance `n` bytes without returning them; false if it can't.
    mutating func skip(_ n: Int) -> Bool
}

extension GGUFByteSource {
    mutating func u32() -> UInt32? { read(4).map { $0.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } } }
    mutating func u64i() -> Int? {
        read(8).map { Int(clamping: $0.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }) }
    }
    mutating func str() -> String? {
        guard let n = u64i(), n >= 0, let b = read(n) else { return nil }
        return String(decoding: b, as: UTF8.self)
    }
    private func leInt(_ b: [UInt8]) -> Int { b.reversed().reduce(0) { ($0 << 8) | Int($1) } }

    /// Decode a value of `type`, or skip it. Returns nil if the buffer/file can't satisfy it.
    mutating func value(type: UInt32) -> GGUFValue? {
        switch type {
        case 0, 1, 7:  return read(1).map { GGUFValue(int: leInt($0)) }   // u8/i8/bool
        case 2, 3:     return read(2).map { GGUFValue(int: leInt($0)) }   // u16/i16
        case 4:        return u32().map { GGUFValue(int: Int($0)) }       // u32
        case 5:        return u32().map { GGUFValue(int: Int(Int32(bitPattern: $0))) }  // i32
        case 6:        return skip(4) ? GGUFValue() : nil                 // f32
        case 10, 11:   return u64i().map { GGUFValue(int: $0) }           // u64/i64
        case 12:       return skip(8) ? GGUFValue() : nil                 // f64
        case 8:        return str().map { GGUFValue(string: $0) }         // string
        case 9:        return skipArray() ? GGUFValue() : nil             // array
        default:       return nil
        }
    }

    /// Advance past an array value: element type (u32), count (u64), then the elements.
    mutating func skipArray() -> Bool {
        guard let etype = u32(), let count = u64i(), count >= 0, count < 100_000_000 else { return false }
        switch etype {
        case 0, 1, 7: return skip(count)
        case 2, 3:    return skip(count * 2)
        case 4, 5, 6: return skip(count * 4)
        case 10, 11, 12: return skip(count * 8)
        case 8:                                   // array of strings — skip each in turn
            for _ in 0 ..< count {
                guard let len = u64i(), len >= 0, skip(len) else { return false }
            }
            return true
        default: return false                     // nested arrays: bail (we never need them)
        }
    }
}

/// Seekable source over a file — skips arbitrarily large arrays without loading them.
private struct FileSource: GGUFByteSource {
    let handle: FileHandle
    mutating func read(_ n: Int) -> [UInt8]? {
        guard n >= 0, n < 100_000_000, let d = try? handle.read(upToCount: n), d.count == n else { return nil }
        return [UInt8](d)
    }
    mutating func skip(_ n: Int) -> Bool {
        guard n >= 0, let off = try? handle.offset() else { return false }
        do { try handle.seek(toOffset: off + UInt64(n)); return true } catch { return false }
    }
}

/// Bounded source over an in-memory buffer (a partial download).
private struct DataSource: GGUFByteSource {
    let bytes: [UInt8]
    var i = 0
    mutating func read(_ n: Int) -> [UInt8]? {
        guard n >= 0, bytes.count - i >= n else { return nil }
        defer { i += n }
        return Array(bytes[i ..< i + n])
    }
    mutating func skip(_ n: Int) -> Bool {
        guard n >= 0, bytes.count - i >= n else { return false }
        i += n
        return true
    }
}
