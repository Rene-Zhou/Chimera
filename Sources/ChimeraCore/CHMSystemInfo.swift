import Foundation

/// CHM /#SYSTEM 元数据。
public struct CHMSystemInfo: Equatable, Sendable {
    /// 书名(code 0,缺省退回 code 3)。
    public var title: String?
    /// 默认显示页(code 2,容器编码字符串)。
    public var defaultTopic: String?
    /// 语言标识(code 4, DWORD)。
    public var lcid: UInt32?

    public init(title: String? = nil, defaultTopic: String? = nil, lcid: UInt32? = nil) {
        self.title = title
        self.defaultTopic = defaultTopic
        self.lcid = lcid
    }
}

/// 解析 /#SYSTEM 二进制块。
///
/// 实测格式(以基准文件 hexdump 破译):`DWORD version + { WORD code, WORD len,
/// data[len] } × N`。字符串按容器 LCID 编码;LCID 条目与字符串条目先后不定,
/// 故两遍扫描:先取 LCID 与原始字节,再用 CHMTextDecoder 解码。
public enum CHMSystemInfoParser {

    /// 解析失败(数据过短/全为垃圾)返回 nil;能解多少是多少,不抛错。
    public static func parse(_ data: Data) -> CHMSystemInfo? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)

        var info = CHMSystemInfo()
        var raws: [UInt16: [UInt8]] = [:]

        var i = 4
        while i + 4 <= bytes.count {
            let code = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            let len = Int(UInt16(bytes[i + 2]) | UInt16(bytes[i + 3]) << 8)
            i += 4
            guard len >= 0, i + len <= bytes.count else { break }
            let chunk = Array(bytes[i..<(i + len)])
            i += len

            if code == 4, chunk.count >= 4, info.lcid == nil {
                info.lcid = UInt32(chunk[0]) | UInt32(chunk[1]) << 8
                    | UInt32(chunk[2]) << 16 | UInt32(chunk[3]) << 24
            } else if code <= 3, raws[code] == nil {
                raws[code] = chunk
            }
        }

        guard info.lcid != nil || !raws.isEmpty else { return nil }

        let decoder = CHMTextDecoder(lcid: info.lcid)
        func string(_ code: UInt16) -> String? {
            guard var raw = raws[code] else { return nil }
            while raw.last == 0 { raw.removeLast() }   // 去尾部 NUL
            guard !raw.isEmpty else { return nil }
            return decoder.decode(Data(raw))
        }
        info.title = string(0) ?? string(3)
        info.defaultTopic = string(2)
        return info
    }
}
