import Foundation
import CChmlib

/// CHM 容器内的一个条目(文件或目录)。
public struct CHMEntry: Equatable, Sendable {
    /// 规范化内部路径,以 "/" 开头,如 "/index.htm"、"/$FIftiMain"。
    public let path: String
    /// 条目解压后的字节长度。
    public let length: UInt64
    /// 是否为目录(CHM 目录路径以 "/" 结尾)。
    public let isDirectory: Bool

    public init(path: String, length: UInt64, isDirectory: Bool) {
        self.path = path
        self.length = length
        self.isDirectory = isDirectory
    }
}

/// CHM 相关错误。
public enum CHMError: Error, Equatable {
    case fileNotFound(String)
    case invalidFormat(String)
    case entryNotFound(String)
    case readFailed(String)
}

/// CHM 文件的 Swift 侧容器抽象:枚举条目、按路径解析、按需读取
/// (LZX 解压由 chmlib 完成)、系统元数据(LCID/标题/默认页)。
/// chmlib 的文件句柄非线程安全,内部以锁串行化。
public final class CHMContainer {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    private var systemInfoCache: CHMSystemInfo?
    private var systemInfoLoaded = false

    public init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CHMError.fileNotFound(path)
        }
        guard let h = chm_open(path) else {
            throw CHMError.invalidFormat(path)
        }
        handle = h
    }

    deinit {
        if let handle { chm_close(handle) }
    }

    // MARK: - 条目

    /// C 回调上下文:只用纯 C 可表示的横式数据,避免从 C 回调直接操作 Swift 堆对象。
    fileprivate struct EnumContext {
        var buffer: UnsafeMutablePointer<chmUnitInfo>?
        var capacity: Int32 = 0
        var count: Int32 = 0
    }

    /// 枚举容器内全部条目(含系统/元数据条目,如 "/$FIftiMain")。
    /// 路径字节按 严格UTF-8 → LCID编码 → GBK 回退链解码。
    public func allEntries() throws -> [CHMEntry] {
        guard let handle else { throw CHMError.invalidFormat("container closed") }
        let lcid = ((try? systemInfo()) ?? nil)?.lcid
        lock.lock()
        defer { lock.unlock() }

        var ctx = EnumContext()
        let callback: CHM_ENUMERATOR = { _, ui, context in
            guard let context, let ui else { return 0 }
            let c = context.assumingMemoryBound(to: EnumContext.self)
            if c.pointee.count == c.pointee.capacity {
                let newCap = max(64, c.pointee.capacity * 2)
                let grown = UnsafeMutablePointer<chmUnitInfo>.allocate(capacity: Int(newCap))
                if let old = c.pointee.buffer {
                    grown.update(from: old, count: Int(c.pointee.count))
                    old.deallocate()
                }
                c.pointee.buffer = grown
                c.pointee.capacity = newCap
            }
            c.pointee.buffer![Int(c.pointee.count)] = ui.pointee
            c.pointee.count += 1
            return 1 // CHM_ENUMERATOR_CONTINUE
        }
        defer { ctx.buffer?.deallocate() }

        guard chm_enumerate(handle, Int32(CHM_ENUMERATE_ALL), callback, &ctx) != 0 else {
            throw CHMError.readFailed("chm_enumerate failed")
        }

        var entries: [CHMEntry] = []
        entries.reserveCapacity(Int(ctx.count))
        if let buffer = ctx.buffer {
            for i in 0..<Int(ctx.count) {
                let info = buffer[i]
                let raw = withUnsafeBytes(of: info.path) { Array($0.prefix(while: { $0 != 0 })) }
                let path = Self.decodePath(raw, lcid: lcid)
                entries.append(
                    CHMEntry(path: path, length: info.length, isDirectory: path.hasSuffix("/"))
                )
            }
        }
        return entries
    }

    /// 按路径解析条目;路径自动补前导 "/";不存在返回 nil。
    /// 注:路径串会以 UTF-8 回传 chmlib —— 适用于 UTF-8 路径容器(含基准文件);
    /// LCID 编码路径的容器请经 allEntries() 查找(已知局限,见 M2 计划)。
    public func entry(at path: String) -> CHMEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entryUnlocked(at: path)
    }

    private func entryUnlocked(at path: String) -> CHMEntry? {
        guard let handle else { return nil }
        let normalized = Self.normalize(path)
        var ui = chmUnitInfo()
        guard chm_resolve_object(handle, normalized, &ui) == CHM_RESOLVE_SUCCESS else {
            return nil
        }
        return CHMEntry(path: normalized, length: ui.length, isDirectory: normalized.hasSuffix("/"))
    }

    // MARK: - 读取

    /// 整读一个条目。
    public func read(_ path: String) throws -> Data {
        guard let entry = entry(at: path) else {
            throw CHMError.entryNotFound(path)
        }
        return try read(path, range: 0..<entry.length)
    }

    /// 按字节区间读取条目(0-based,相对条目内容起点)。
    public func read(_ path: String, range: Range<UInt64>) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entryUnlocked(at: path) else {
            throw CHMError.entryNotFound(path)
        }
        guard range.upperBound <= entry.length else {
            throw CHMError.readFailed(
                "range \(range) out of bounds for \(path)(length \(entry.length))"
            )
        }
        return try readUnlocked(entry: entry, range: range)
    }

    /// 调用方必须已持锁。
    private func readUnlocked(entry: CHMEntry, range: Range<UInt64>) throws -> Data {
        guard let handle else { throw CHMError.invalidFormat("container closed") }
        let total = Int(range.count)
        guard total > 0 else { return Data() }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: total, alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }

        var ui = chmUnitInfo()
        guard chm_resolve_object(handle, entry.path, &ui) == CHM_RESOLVE_SUCCESS else {
            throw CHMError.entryNotFound(entry.path)
        }

        var filled = 0
        while filled < total {
            // 注意:chm_retrieve_object 的 addr 是条目内相对偏移
            // (内部会加上 ui->start),传绝对地址会触发 addr >= ui->length 检查而返回 0
            let n = chm_retrieve_object(
                handle,
                &ui,
                buffer.advanced(by: filled).assumingMemoryBound(to: UInt8.self),
                range.lowerBound + UInt64(filled),
                Int64(total - filled)
            )
            guard n > 0 else {
                throw CHMError.readFailed("short read at \(filled)/\(total) of \(entry.path)")
            }
            filled += Int(n)
        }
        return Data(bytes: buffer, count: total)
    }

    // MARK: - 系统元数据

    /// /#SYSTEM 解析结果(缓存);文件不含该条目时返回 nil。
    public func systemInfo() throws -> CHMSystemInfo? {
        lock.lock()
        defer { lock.unlock() }
        if systemInfoLoaded { return systemInfoCache }
        systemInfoLoaded = true
        if let entry = entryUnlocked(at: "/#SYSTEM"), entry.length <= 0x100000,
           let raw = try? readUnlocked(entry: entry, range: 0..<entry.length) {
            systemInfoCache = CHMSystemInfoParser.parse(raw)
        }
        return systemInfoCache
    }

    // MARK: - 路径解码

    /// 内部路径字节 → 文本:严格 UTF-8 → LCID 编码 → GBK → 有损。
    /// (基准文件为 UTF-8 路径;典型 Windows 生成文件为 LCID 编码路径)
    static func decodePath(_ bytes: [UInt8], lcid: UInt32?) -> String {
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        if let lcid, let e = CHMCharset.encoding(forLCID: lcid),
           let s = String(bytes: bytes, encoding: e) { return s }
        if let e = CHMCharset.encoding(forIANA: "GBK"),
           let s = String(bytes: bytes, encoding: e) { return s }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func normalize(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/" + path
    }
}
