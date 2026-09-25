import Foundation

/// CHM 语言环境(LCID)与字符集工具。
public enum CHMCharset {
    /// IANA 名(含常见别名,全部小写)→ String.Encoding。
    /// CF 派生编码的 NSStringEncoding 原始值 = 0x8000_0000 | CFStringEncoding,
    /// 数值由 macOS 27 SDK 的 CFStringConvertIANACharSetNameToEncoding 实测得出
    /// (Swift 侧 CF 转换函数在新 SDK 不可见,故硬编码);windows-125x 走原生常量。
    static let table: [String: String.Encoding] = [
        "utf-8": .utf8, "utf8": .utf8,
        "us-ascii": .ascii, "ascii": .ascii,
        "iso-8859-1": .isoLatin1, "latin1": .isoLatin1, "l1": .isoLatin1,
        "gbk": String.Encoding(rawValue: 0x80000631),
        "gb18030": String.Encoding(rawValue: 0x80000632),
        "gb2312": String.Encoding(rawValue: 0x80000930),
        "big5": String.Encoding(rawValue: 0x80000A03),
        "big5-hkscs": String.Encoding(rawValue: 0x80000A06),
        "euc-kr": String.Encoding(rawValue: 0x80000940),
        "ks_c_5601-1987": String.Encoding(rawValue: 0x80000940),
        "shift_jis": String.Encoding(rawValue: 0x80000A01),
        "shift-jis": String.Encoding(rawValue: 0x80000A01),
        "sjis": String.Encoding(rawValue: 0x80000A01),
        "x-sjis": String.Encoding(rawValue: 0x80000A01),
        "windows-31j": String.Encoding(rawValue: 0x80000A01),
        "euc-jp": .japaneseEUC,
        "windows-1250": .windowsCP1250,
        "windows-1251": .windowsCP1251,
        "windows-1252": .windowsCP1252,
        "windows-1253": .windowsCP1253,
        "windows-1254": .windowsCP1254,
    ]

    /// IANA/常见别名 → String.Encoding;无法识别返回 nil。

    /// LCID(LANGID 部分)→ IANA charset 名;未覆盖语言返回 nil。
    /// 中文需按子语言区分简体(GBK)/繁体(Big5)。
    public static func name(forLCID lcid: UInt32) -> String? {
        let langid = UInt16(lcid & 0xFFFF)
        let primary = langid & 0x3FF
        switch primary {
        case 0x04: // 中文,按子语言区分
            switch langid >> 10 {
            case 0x01, 0x03, 0x05: return "Big5"     // zh-TW / zh-HK / zh-MO
            default: return "GBK"                    // zh-CN / zh-SG 及默认
            }
        case 0x11: return "Shift_JIS"                // 日
        case 0x12: return "EUC-KR"                   // 韩
        case 0x19: return "windows-1251"             // 俄
        case 0x08: return "windows-1253"             // 希腊
        case 0x1F: return "windows-1254"             // 土耳其
        case 0x05, 0x0E, 0x15, 0x1B, 0x24: return "windows-1250" // 中东欧(捷/匈/波/斯洛伐克/斯洛文尼亚)
        case 0x09, 0x07, 0x0C, 0x0A, 0x10, 0x13, 0x14,
             0x16, 0x1D, 0x0B, 0x0F, 0x25: return "windows-1252"  // 西文系
        default: return nil
        }
    }

    /// IANA/常见别名 → String.Encoding;无法识别返回 nil。
    public static func encoding(forIANA name: String) -> String.Encoding? {
        table[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// LCID → String.Encoding。
    public static func encoding(forLCID lcid: UInt32) -> String.Encoding? {
        name(forLCID: lcid).flatMap(encoding(forIANA:))
    }

    /// 从前 4KB 粗提 `<meta charset=…>` 声明(与渲染管线 CHMSchemeHandler 行为一致)。
    /// 兼容单/双引号包裹与无引号(以空白/`;`/`>`/引号 结尾)两种形态;无声明返回 nil。
    public static func declared(in data: Data) -> String? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        guard let r = head.range(of: "charset=", options: .caseInsensitive) else { return nil }
        var s = head[r.upperBound...]
        if s.first == "\"" || s.first == "'" {
            let quote = s.removeFirst()
            guard let end = s.firstIndex(of: quote) else { return nil }
            s = s[..<end]
        } else if let end = s.firstIndex(where: {
            // http-equiv 形态下 charset 值常以属性闭引号结尾,故引号也算终止符
            $0 == ";" || $0 == ">" || $0 == "\"" || $0 == "'" || $0.isWhitespace
        }) {
            s = s[..<end]
        }
        let name = s.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// CHM 文本解码器:PRD F2 的三级回退策略。
///
/// 回退顺序(强 → 弱):
/// 1. BOM(UTF-8 / UTF-16LE / UTF-16BE)
/// 2. HTML charset 声明
/// 3. 内容嗅探:严格 UTF-8
/// 4. CHM 头 LCID
/// 5. GBK 兜底(中文 CHM 惯例;GB18030 超集)
/// 6. 有损 UTF-8(替换字符)
public struct CHMTextDecoder {
    public let lcid: UInt32?
    public let declaredCharset: String?

    public init(lcid: UInt32? = nil, declaredCharset: String? = nil) {
        self.lcid = lcid
        self.declaredCharset = declaredCharset
    }

    public func decode(_ data: Data) -> String {
        // 1) BOM
        if data.count >= 3, data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.count >= 2 {
            let head = [UInt8](data.prefix(2))
            if head == [0xFF, 0xFE] {
                return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
            }
            if head == [0xFE, 0xFF] {
                return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
            }
        }

        // 2) 声明的 charset(解码必须整体成功,否则视为声明不可信)
        if let cs = declaredCharset,
           let enc = CHMCharset.encoding(forIANA: cs),
           let s = String(data: data, encoding: enc) {
            return s
        }

        // 3) 内容嗅探:严格 UTF-8(GBK 中文序列几乎不可能是合法 UTF-8;
        //    反之 UTF-8 字节几乎总能被 GBK“成功”解出乱码,故 UTF-8 必须先于 LCID)
        if let s = String(data: data, encoding: .utf8) {
            return s
        }

        // 4) LCID
        if let lcid,
           let enc = CHMCharset.encoding(forLCID: lcid),
           let s = String(data: data, encoding: enc) {
            return s
        }

        // 5) GBK 兜底
        if let enc = CHMCharset.encoding(forIANA: "GBK"),
           let s = String(data: data, encoding: enc) {
            return s
        }

        // 6) 有损
        return String(decoding: data, as: UTF8.self)
    }

    /// 按页解码:每页独立嗅探 `<meta charset>` 声明(与渲染管线一致),再走完整回退链。
    /// 搜索索引构建等批量场景应使用本方法,而非对全部页面共用单一 decoder。
    public static func decode(_ data: Data, lcid: UInt32?) -> String {
        CHMTextDecoder(lcid: lcid, declaredCharset: CHMCharset.declared(in: data)).decode(data)
    }
}
