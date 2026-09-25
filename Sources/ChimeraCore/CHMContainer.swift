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

/// CHM 文件的 Swift 侧容器抽象:枚举条目、按路径解析、按需读取(LZX 解压由 chmlib 完成)。
/// chmlib 的文件句柄非线程安全,内部以锁串行化。
public final class CHMContainer {
    private var handle: OpaquePointer?
    private let lock = NSLock()

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

    /// C 回调上下文:只用纯 C 可表示的横式数据,避免从 C 回调直接操作 Swift 堆对象。
    fileprivate struct EnumContext {
        var buffer: UnsafeMutablePointer<chmUnitInfo>?
        var capacity: Int32 = 0
        var count: Int32 = 0
    }

    /// 枚举容器内全部条目(含系统/元数据条目,如 "/$FIftiMain")。
    public func allEntries() throws -> [CHMEntry] {
        guard let handle else { throw CHMError.invalidFormat("container closed") }
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
                let path = withUnsafeBytes(of: info.path) { bytes in
                    String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                entries.append(
                    CHMEntry(path: path, length: info.length, isDirectory: path.hasSuffix("/"))
                )
            }
        }
        return entries
    }

    /// 按路径解析条目;路径自动补前导 "/";不存在返回 nil。
    public func entry(at path: String) -> CHMEntry? {
        guard let handle else { return nil }
        let normalized = Self.normalize(path)
        lock.lock()
        defer { lock.unlock() }

        var ui = chmUnitInfo()
        guard chm_resolve_object(handle, normalized, &ui) == CHM_RESOLVE_SUCCESS else {
            return nil
        }
        return CHMEntry(path: normalized, length: ui.length, isDirectory: normalized.hasSuffix("/"))
    }

    /// 整读一个条目。
    public func read(_ path: String) throws -> Data {
        guard let entry = entry(at: path) else {
            throw CHMError.entryNotFound(path)
        }
        return try read(path, range: 0..<entry.length)
    }

    /// 按字节区间读取条目(0-based,相对条目内容起点)。
    public func read(_ path: String, range: Range<UInt64>) throws -> Data {
        guard let handle else { throw CHMError.invalidFormat("container closed") }
        guard let entry = entry(at: path) else {
            throw CHMError.entryNotFound(path)
        }
        guard range.upperBound <= entry.length else {
            throw CHMError.readFailed(
                "range \(range) out of bounds for \(path)(length \(entry.length))"
            )
        }

        let total = Int(range.count)
        guard total > 0 else { return Data() }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: total, alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }

        lock.lock()
        defer { lock.unlock() }

        var ui = chmUnitInfo()
        guard chm_resolve_object(handle, entry.path, &ui) == CHM_RESOLVE_SUCCESS else {
            throw CHMError.entryNotFound(path)
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
                throw CHMError.readFailed("short read at \(filled)/\(total) of \(path)")
            }
            filled += Int(n)
        }
        return Data(bytes: buffer, count: total)
    }

    static func normalize(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/" + path
    }
}
