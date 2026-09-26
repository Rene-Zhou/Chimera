import Foundation
import CryptoKit

// MARK: - 文本抽取

/// HTML → 纯文本/标题 工具(搜索索引与摘要的基础)。
public enum CHMTextExtractor {

    /// 提取 `<title>`(实体解码后);无则 nil。
    public static func title(from html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let gt = html[open.upperBound...].firstIndex(of: ">"),
              let close = html.range(of: "</title>", options: .caseInsensitive,
                                     range: gt..<html.endIndex) else { return nil }
        guard gt < close.lowerBound else { return nil }
        let raw = String(html[html.index(after: gt)..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let t = CHMSitemapParser.decodeEntities(raw)
        return t.isEmpty ? nil : t
    }

    /// 抽取 h1~h6 小标题(小标题加权用):每条标题独立成元素,内容片段经
    /// plainText(内层标签→空格/实体解码/空白折叠);无匹配返回空数组。
    /// 大小写不敏感;不闭合的标题取到下一个标题开标签或串尾;
    /// `<head>`/`<hr>` 等非数字标题标签不匹配。注:极罕见的
    /// script/注释内出现的标题标记会被误抽(可容忍的噪声)。
    public static func headings(from html: String) -> [String] {
        var parts: [String] = []
        var cursor = html.startIndex
        while let open = nextHeadingOpen(html, from: cursor) {
            if open.isSelfClosing {
                cursor = open.tagEnd   // <h2/> 自闭合:无内容,不吞噬后续
            } else if let close = html.range(of: "</h\(open.level)>", options: .caseInsensitive,
                                      range: open.tagEnd..<html.endIndex) {
                if open.tagEnd < close.lowerBound {
                    let text = plainText(from: String(html[open.tagEnd..<close.lowerBound]))
                    if !text.isEmpty { parts.append(text) }
                }
                cursor = close.upperBound
            } else if let next = nextHeadingOpen(html, from: open.tagEnd) {
                // 不闭合:内容取到下一个标题开标签
                if open.tagEnd < next.openLower {
                    let text = plainText(from: String(html[open.tagEnd..<next.openLower]))
                    if !text.isEmpty { parts.append(text) }
                }
                cursor = next.openLower
            } else {
                // 不闭合且再无标题:取到串尾
                if open.tagEnd < html.endIndex {
                    let text = plainText(from: String(html[open.tagEnd...]))
                    if !text.isEmpty { parts.append(text) }
                }
                cursor = html.endIndex
            }
        }
        return parts
    }

    /// 一个 h1~h6 开标签:层级、'<' 位置、标签结束('>' 之后)位置。
    private struct HeadingOpen {
        let level: Int
        let openLower: String.Index
        let tagEnd: String.Index
        /// <h2/> 自闭合(无内容)。
        let isSelfClosing: Bool
    }

    /// 从 from 起找下一个标题开标签:`<h`+数字 1~6 且后随非字母数字
    /// (排除 <head>/<hr>/<h7> 及 <h2x> 之类);找不到返回 nil。
    private static func nextHeadingOpen(_ html: String, from: String.Index) -> HeadingOpen? {
        var i = from
        while let lt = html.range(of: "<h", options: .caseInsensitive,
                                  range: i..<html.endIndex) {
            let afterH = lt.upperBound
            guard afterH < html.endIndex,
                  let level = Int(String(html[afterH])), (1...6).contains(level) else {
                i = lt.upperBound
                continue
            }
            let afterDigit = html.index(after: afterH)
            if afterDigit < html.endIndex {
                let c = html[afterDigit]
                if c.isLetter || c.isNumber {
                    i = afterH
                    continue
                }
            }
            guard let gt = html[afterH...].firstIndex(of: ">") else { return nil }
            let selfClosing = html[html.index(before: gt)] == "/"
            return HeadingOpen(level: level, openLower: lt.lowerBound,
                               tagEnd: html.index(after: gt), isSelfClosing: selfClosing)
        }
        return nil
    }

    /// HTML → 纯文本:移除 script/style 块,标签转空白,实体解码,空白折叠。
    /// 两趟 UTF-8 字节扫描(P1-9):第一趟块跳过+标签→空格,第二趟实体解码+空白折叠;
    /// 逐字节而非逐 Character——debug 构建下字素级迭代每字符代价高一个量级,
    /// 且旧实现的 removeSubrange/多次全文拷贝在多块页面上是 O(n·k)。
    public static func plainText(from html: String) -> String {
        // 附带修复:decode 产出的页可能桥接自 NSString(逐字符访问慢近一个量级),
        // 先物化为连续 UTF-8 的 native 串(已是 native 时零拷贝)
        let source: String
        if html.utf8.withContiguousStorageIfAvailable({ _ in true }) == true {
            source = html
        } else {
            source = String(decoding: html.utf8, as: UTF8.self)
        }
        let bytes = Array(source.utf8)
        let n = bytes.count

        // ===== 第一趟:script/style 区间整体跳过(含未闭合:丢弃至串尾,与旧实现一致);
        // 其余标签 → 空格(裸 ">" 丢弃);文本字节透传。
        // UTF-8 下 0x3C("<")/0x3E(">") 只能是独立 ASCII 字节,逐字节判断安全。
        // 预分配 + 写指针:避免逐字节 append 的容量检查/函数调用开销
        var stripped = [UInt8](repeating: 0, count: n)
        var w = 0
        var i = 0
        var inTag = false
        while i < n {
            let b = bytes[i]
            if b == 0x3C {
                // 快速排除:script/style 开标签的第二个字节必为 's'/'S'
                let next = i + 1 < n ? bytes[i + 1] : 0
                if (next == 0x73 || next == 0x53), let tag = matchScriptStyleOpen(bytes, at: i) {
                    // 前缀匹配与旧实现 range(of: "<script") 一致(其后字符任意)
                    if let closeEnd = findCloseTag(bytes, from: i + 1, tag: tag) {
                        i = closeEnd
                    } else {
                        i = n // 未闭合块:移除到末尾
                    }
                    continue
                }
                stripped[w] = 0x20
                w += 1
                inTag = true
            } else if b == 0x3E {
                inTag = false
            } else if !inTag {
                stripped[w] = b
                w += 1
            }
            i += 1
        }

        // ===== 第二趟:实体解码 + 空白折叠(逐字语义与旧 decodeEntities→折叠链一致;
        // 解码在标签移除之后,`&lt;script&gt;` 解出的 "<script>" 是文本,不再按块处理)
        var out = [UInt8](repeating: 0, count: w)
        var ow = 0
        let m = w
        var j = 0
        var lastWasSpace = true
        while j < m {
            let b = stripped[j]
            if b == 0x26 { // '&':复刻 decodeEntities,向后 11 字节内找 ';',实体名 ≤ 10 字节
                var name = [UInt8]()
                name.reserveCapacity(11)
                var k = j + 1
                var semi = -1
                while k <= min(j + 11, m - 1) {
                    let c = stripped[k]
                    if c == 0x3B { semi = k; break }
                    name.append(asciiLower(c))
                    k += 1
                }
                if semi >= 0, let scalar = Self.decodeEntity(name) {
                    // 有效实体:输出解码标量(空白则参与折叠),跳过 ';'
                    emitScalar(scalar, to: &out, write: &ow, lastWasSpace: &lastWasSpace)
                    j = semi + 1
                    continue
                }
                // 非法/超长实体: '&' 作普通字节输出,后续字节正常处理(与旧实现一致)
            }
            if b < 0x80 {
                // ASCII:仅 0x09-0x0D 与 0x20 是空白
                if b == 0x20 || (b >= 0x09 && b <= 0x0D) {
                    if !lastWasSpace {
                        out[ow] = 0x20
                        ow += 1
                        lastWasSpace = true
                    }
                } else {
                    out[ow] = b
                    ow += 1
                    lastWasSpace = false
                }
                j += 1
            } else {
                // 多字节标量:空白标量的 UTF-8 前导字节仅 C2/E1/E2/E3,
                // 其余(如 CJK E4-E9)直接透传整个标量(内联判定,避免每标量函数调用)
                let len = utf8ScalarLength(lead: b)
                var isWS = false
                if b == 0xC2 || b == 0xE1 || b == 0xE2 || b == 0xE3 {
                    // 手动解码标量(while 循环,避免 Range 迭代器的泛型开销)
                    var v: UInt32 = UInt32(b & 0x0F)
                    var q = 1
                    while q < len {
                        v = (v << 6) | UInt32(stripped[j + q] & 0x3F)
                        q += 1
                    }
                    switch v {
                    case 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
                        isWS = true
                    default:
                        break
                    }
                }
                if isWS {
                    if !lastWasSpace {
                        out[ow] = 0x20
                        ow += 1
                        lastWasSpace = true
                    }
                } else {
                    var q = 0
                    while q < len {
                        out[ow + q] = stripped[j + q]
                        q += 1
                    }
                    ow += len
                    lastWasSpace = false
                }
                j += len
            }
        }
        if lastWasSpace && ow > 0 { ow -= 1 }
        return String(decoding: out[0..<ow], as: UTF8.self)
    }

    /// 实体名(已小写化字节)→ 标量;无效返回 nil。
    /// 语义与 CHMSitemapParser.decodeEntities 一致:十进制/十六进制 + 常用具名实体。
    private static func decodeEntity(_ name: [UInt8]) -> UInt32? {
        if name.count >= 2, name[0] == 0x23 { // '#'
            let digits: [UInt8] = name[1] == 0x78 ? Array(name[2...]) : Array(name[1...])
            guard !digits.isEmpty else { return nil }
            let s = String(decoding: digits, as: UTF8.self)
            if name[1] == 0x78 { return UInt32(s, radix: 16) }
            return UInt32(s)
        }
        switch String(decoding: name, as: UTF8.self) {
        case "amp": return 0x26
        case "lt": return 0x3C
        case "gt": return 0x3E
        case "quot": return 0x22
        case "apos": return 0x27
        case "nbsp": return 0xA0
        default: return nil
        }
    }

    /// 标量经空白判断输出:空白折叠为单个空格,否则追加 UTF-8 编码(写指针式)。
    private static func emitScalar(_ value: UInt32, to out: inout [UInt8],
                                   write ow: inout Int, lastWasSpace: inout Bool) {
        // Unicode 空白标量全集(与旧 Character.isWhitespace 判定一致)
        let isWS: Bool
        switch value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            isWS = true
        default:
            isWS = false
        }
        if isWS {
            if !lastWasSpace {
                out[ow] = 0x20
                ow += 1
                lastWasSpace = true
            }
        } else {
            if value < 0x80 {
                out[ow] = UInt8(value)
                ow += 1
            } else if value < 0x800 {
                out[ow] = UInt8(0xC0 | (value >> 6))
                out[ow + 1] = UInt8(0x80 | (value & 0x3F))
                ow += 2
            } else if value < 0x10000 {
                out[ow] = UInt8(0xE0 | (value >> 12))
                out[ow + 1] = UInt8(0x80 | ((value >> 6) & 0x3F))
                out[ow + 2] = UInt8(0x80 | (value & 0x3F))
                ow += 3
            } else {
                out[ow] = UInt8(0xF0 | (value >> 18))
                out[ow + 1] = UInt8(0x80 | ((value >> 12) & 0x3F))
                out[ow + 2] = UInt8(0x80 | ((value >> 6) & 0x3F))
                out[ow + 3] = UInt8(0x80 | (value & 0x3F))
                ow += 4
            }
            lastWasSpace = false
        }
    }

    private static func asciiLower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
    }

    /// UTF-8 前导字节 → 标量字节长度(输入来自合法 String,无非法序列)。
    private static func utf8ScalarLength(lead: UInt8) -> Int {
        if lead >= 0xF0 { return 4 }
        if lead >= 0xE0 { return 3 }
        return 2
    }

    /// bytes[i] == '<' 处是否紧跟 script/style(ASCII 大小写不敏感前缀匹配)。
    /// 返回对应闭标签模式(nil = 非块开标签)。模式均为静态常量,调用零分配。
    private static let scriptOpen: [UInt8] = [0x73, 0x63, 0x72, 0x69, 0x70, 0x74] // "script"
    private static let styleOpen: [UInt8] = [0x73, 0x74, 0x79, 0x6C, 0x65]       // "style"
    private static let closeScriptTag: [UInt8] = Array("</script>".utf8)
    private static let closeStyleTag: [UInt8] = Array("</style>".utf8)

    private static func matchScriptStyleOpen(_ bytes: [UInt8], at i: Int) -> [UInt8]? {
        if matchesASCII(bytes, at: i + 1, scriptOpen) { return closeScriptTag }
        if matchesASCII(bytes, at: i + 1, styleOpen) { return closeStyleTag }
        return nil
    }

    /// bytes[start...] 是否与 tag(小写 ASCII)逐字节匹配(大小写不敏感)。
    private static func matchesASCII(_ bytes: [UInt8], at start: Int, _ tag: [UInt8]) -> Bool {
        var k = start
        var t = 0
        while t < tag.count {
            if k >= bytes.count || !asciiEqByte(bytes[k], tag[t]) { return false }
            k += 1
            t += 1
        }
        return true
    }

    private static func asciiEqByte(_ b: UInt8, _ lower: UInt8) -> Bool {
        b == lower || (b >= 0x41 && b <= 0x5A && b + 0x20 == lower)
    }

    private static func findCloseTag(_ bytes: [UInt8], from: Int, tag close: [UInt8]) -> Int? {
        let n = bytes.count
        let len = close.count
        var i = from
        while i + len <= n {
            if bytes[i] == 0x3C {
                var ok = true
                var k = 0
                while k < len {
                    if !asciiEqByte(bytes[i + k], close[k]) { ok = false; break }
                    k += 1
                }
                if ok { return i + len }
            }
            i += 1
        }
        return nil
    }
}

// MARK: - 摘要

/// 命中上下文摘要。
public enum CHMSnippet {
    /// text 中 offset 处 ±radius 字符窗口;截断侧以 "…" 标记;折叠换行。
    /// 直接用 String.Index 定位窗口边界(P1-7),不再 `Array(text)` 整页拷贝;
    /// 换行折叠与连续空格合并为单趟扫描。
    public static func around(_ offset: Int, in text: String, radius: Int = 40) -> String {
        guard !text.isEmpty else { return "" }
        let count = text.count
        let clamped = min(max(offset, 0), count - 1)
        let start = max(0, clamped - radius)
        let end = min(count, clamped + 2 * radius)
        let startIdx = text.index(text.startIndex, offsetBy: start)
        let endIdx = text.index(startIdx, offsetBy: end - start)
        var s = String(text[startIdx..<endIdx])
        if start > 0 { s = "…" + s }
        if end < count { s += "…" }

        // 单趟:\n/\r → 空格,连续空格(含替换产物)合并为一个;
        // 制表符等其他空白与旧行为一致:不替换、不折叠
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s {
            if ch == " " || ch == "\n" || ch == "\r" {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }
}

// MARK: - 索引

/// 单页索引文档。
public struct CHMSearchDocument: Codable, Equatable, Sendable {
    /// 内部路径,如 "/玩家手册2024.htm"。
    public let path: String
    /// 页面标题(TOC 标题优先,`<title>` 兜底)。
    public let title: String
    /// 抽取后的纯文本。
    public let text: String
    /// h1~h6 小标题(每条独立;小标题加权用);旧缓存缺该键解码为空数组。
    public let headings: [String]
    /// 预计算的小写正文/标题:大小写折叠在构建/解码期只做一次,
    /// 搜索时走纯子串匹配(大书上比逐页 caseInsensitive 快一个量级)。
    /// 不随缓存持久化,解码时重算。
    let textLower: String
    let titleLower: String
    let headingsLower: [String]

    public init(path: String, title: String, text: String, headings: [String] = []) {
        self.path = path
        self.title = title
        self.text = text
        self.headings = headings
        self.textLower = text.lowercased()
        self.titleLower = title.lowercased()
        self.headingsLower = headings.map { $0.lowercased() }
    }

    private enum CodingKeys: String, CodingKey { case path, title, text, headings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try c.decode(String.self, forKey: .path),
            title: try c.decode(String.self, forKey: .title),
            text: try c.decode(String.self, forKey: .text),
            // 兕底旧缓存:headings 键缺失时为空数组;类型不符(短暂存在过的
            // 字符串型)则抛错→整体索引加载失败→自动重建恢复信号
            headings: try c.decodeIfPresent([String].self, forKey: .headings) ?? []
        )
    }
}

/// 全文索引:内存搜索 + 磁盘缓存(PropertyList 二进制)。
public struct CHMSearchIndex: Codable {
    public let documents: [CHMSearchDocument]

    public init(documents: [CHMSearchDocument]) {
        self.documents = documents
    }

    /// 从容器构建:遍历全部 HTML 条目,读取→按页解码(每页嗅探 charset 声明)→标题→纯文本。
    /// - Parameters:
    ///   - tocTitles: TOC 映射(local 路径(带/不带前导 /)→ 标题),优先作为标题
    ///   - progress: 每完成一页回调 (done, total)
    public static func build(
        container: CHMContainer,
        tocTitles: [String: String] = [:],
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> CHMSearchIndex {
        try build(container: container, entries: try container.allEntries(),
                  tocTitles: tocTitles, progress: progress)
    }

    /// 同上,但接收调用方已枚举的条目(allEntries() 结果)以复用枚举。
    /// 内部自行过滤 .htm/.html 非目录条目。
    /// - Parameters:
    ///   - onReadFailure: 读取失败页回调(路径);失败页被计数并汇总打印,不中断构建
    public static func build(
        container: CHMContainer,
        entries: [CHMEntry],
        tocTitles: [String: String] = [:],
        progress: ((Int, Int) -> Void)? = nil,
        onReadFailure: ((String) -> Void)? = nil
    ) throws -> CHMSearchIndex {
        let info = try container.systemInfo()
        let htmlEntries = entries
            .filter { entry in
                !entry.isDirectory
                    && ["htm", "html"].contains((entry.path as NSString).pathExtension.lowercased())
            }
            // P0-4:按数据区物理偏移升序读取。LZX 解压有状态,目录序随机访问会
            // 反复重解压自上次 reset 以来的全部块;物理序访问近乎顺序,几乎零重解压。
            // 同偏移按路径排序保证结果确定性。注意:documents 顺序随之变为物理序,
            // 搜索同分结果的文档序排列随之变化(可接受的行为变化)。
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.path < $1.path }
        // P0-4:调大 LZX 块缓存(默认仅 5×32KB;128 块 ≈ 4MB,显著减少重复解压)
        container.setCacheBlockCount(128)

        var docs: [CHMSearchDocument] = []
        docs.reserveCapacity(htmlEntries.count)
        var failedPaths: [String] = []
        for (i, entry) in htmlEntries.enumerated() {
            do {
                // P0-4:零 resolve 读取,免每次读取的目录页查找
                let data = try container.read(entry: entry)
                let html = CHMTextDecoder.decode(data, lcid: info?.lcid)
                let bare = String(entry.path.dropFirst())
                let title = tocTitles[entry.path] ?? tocTitles[bare]
                    ?? CHMTextExtractor.title(from: html) ?? entry.path
                let text = CHMTextExtractor.plainText(from: html)
                if !text.isEmpty {
                    docs.append(CHMSearchDocument(
                        path: entry.path, title: title, text: text,
                        headings: CHMTextExtractor.headings(from: html)))
                }
            } catch {
                // P2-12:记录失败页并回调,不再无声跳过
                failedPaths.append(entry.path)
                onReadFailure?(entry.path)
            }
            progress?(i + 1, htmlEntries.count)
        }
        if !failedPaths.isEmpty {
            let sample = failedPaths.prefix(5).joined(separator: ", ")
            let more = failedPaths.count > 5 ? ", …" : ""
            print("index build: \(failedPaths.count)/\(htmlEntries.count) pages failed: "
                + "[\(sample)\(more)]")
        }
        return CHMSearchIndex(documents: docs)
    }

    /// 大小写不敏感子串搜索;等价于 `searchResults(query, limit:).hits`。
    public func search(_ query: String, limit: Int = 100) -> [CHMSearchHit] {
        searchResults(query, limit: limit).hits
    }

    /// 相关度搜索:查询按空白分词(按小写去重),**全部词命中(正文/标题/小标题)
    /// 才入选**(AND,零结果不回退 OR);整串连续出现(短语)总分 ×1.5。
    /// 打分信号(降序,同分按文档顺序):
    /// - 标题分级:标题==词 ×8 / 前缀 ×5 / 包含 ×2;
    /// - 小标题分级(h1~h6,构建期按条抽取):单条 == ×6 / 前缀 ×5 / 包含 ×3,
    ///   每词取各标题最优档(多标题页不因拼接稀释精确/前缀信号);
    /// - 正文词频:每词 1+ln(加权词频);ASCII 字母数字词的整词出现
    ///   (前后非字母数字)按双倍计,纯子串命中(如 "art" 命中 "start")单倍;
    /// - 首现位置:越早越加分 1/(1+ln(1+首现字节偏移/文长));
    /// - 密度归一:正文分除以 sqrt(文长/平均文长)(钳制 [0.5,4]),同频次短页优先。
    /// 单词查询的命中文档集合与旧"整样子串匹配"完全一致,仅排序变化。
    /// `total` 为未应用 limit 截断前的总命中文档数。
    public func searchResults(_ query: String, limit: Int = 100) -> CHMSearchResults {
        guard let parsed = Self.parseQuery(query) else { return CHMSearchResults(hits: [], total: 0) }
        let scored = scoredDocuments(terms: parsed.terms, phrase: parsed.phrase)
        return CHMSearchResults(hits: Array(scored.prefix(limit)).map(\.hit), total: scored.count)
    }

    // MARK: 相关度打分(查询期;索引不含分数,旧缓存直接兼容)

    /// 查询词(原始大小写用于偏移回退重查;小写用于匹配)。
    struct QueryTerm {
        let raw: String
        let lower: String
    }

    /// 单词在正文(textLower)中的扫描结果。
    struct TermScan {
        var count = 0
        /// 整词出现次数(仅 ASCII 字母数字词统计,其余恒为 0)。
        var wordCount = 0
        /// 首现区间(摘要/偏移定位用)。
        var firstRange: Range<String.Index>?
    }

    /// 带分数的命中(排序中间产物;测试/诊断观测口)。
    struct ScoredHit {
        let score: Double
        let hit: CHMSearchHit
    }

    /// 查询解析:修剪、空白分词、按小写有序去重;空查询返回 nil。
    static func parseQuery(_ query: String) -> (terms: [QueryTerm], phrase: String)? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        var terms: [QueryTerm] = []
        var seen = Set<String>()
        for part in q.split(whereSeparator: \.isWhitespace) {
            let lower = String(part).lowercased()
            guard seen.insert(lower).inserted else { continue }
            terms.append(QueryTerm(raw: String(part), lower: lower))
        }
        guard !terms.isEmpty else { return nil }
        return (terms, q.lowercased())
    }

    /// 打分并排序:(分数 desc, 文档顺序 asc);searchResults 与 scoredResults 共用。
    /// 每文档独立打分,沿用并发结构;tf 计数为单调推进的 range 搜索,摊销 O(n)
    /// (未命中文档成本与旧首现搜索相同)。
    func scoredDocuments(terms: [QueryTerm], phrase: String) -> [ScoredHit] {
        let avgLen = max(1.0, Double(documents.reduce(0) { $0 + $1.textLower.utf8.count })
            / Double(max(documents.count, 1)))
        var slots = [ScoredHit?](repeating: nil, count: documents.count)
        DispatchQueue.concurrentPerform(iterations: documents.count) { i in
            slots[i] = Self.scoreDocument(documents[i], terms: terms, phrase: phrase, avgLen: avgLen)
        }
        return slots.enumerated()
            .compactMap { entry in entry.element.map { (index: entry.offset, scored: $0) } }
            .sorted { $0.scored.score != $1.scored.score
                ? $0.scored.score > $1.scored.score : $0.index < $1.index }
            .map(\.scored)
    }

    /// 带分数的搜索结果(观测口:测试打印 top-N 与耗时)。
    func scoredResults(_ query: String) -> [ScoredHit] {
        guard let parsed = Self.parseQuery(query) else { return [] }
        return scoredDocuments(terms: parsed.terms, phrase: parsed.phrase)
    }

    /// 单文档打分;任一词正文/标题均未命中 → nil(AND 排除)。
    private static func scoreDocument(
        _ doc: CHMSearchDocument, terms: [QueryTerm], phrase: String, avgLen: Double
    ) -> ScoredHit? {
        let byteLen = Double(doc.textLower.utf8.count)
        var bodyScore = 0.0
        var titleScore = 0.0
        var headingScore = 0.0
        var anyTitle = false
        var firstTitleOffset: Int?
        var firstHeadingHit: (term: QueryTerm, headingIndex: Int)?
        var bodyScans: [(term: QueryTerm, scan: TermScan)] = []

        for t in terms {
            let scan = scanTerm(t.lower, in: doc.textLower,
                                wordBoundary: isASCIIAlphanumeric(t.lower))
            var grade = 0.0
            if doc.titleLower == t.lower { grade = 8 }
            else if doc.titleLower.hasPrefix(t.lower) { grade = 5 }
            else if doc.titleLower.contains(t.lower) { grade = 2 }
            if grade > 0 {
                anyTitle = true
                if firstTitleOffset == nil { firstTitleOffset = titleOffset(t, in: doc) }
            }
            var hgrade = 0.0
            var bestHeading: Int? = nil
            for (hi, h) in doc.headingsLower.enumerated() {
                let g: Double
                if h == t.lower { g = 6 }
                else if h.hasPrefix(t.lower) { g = 5 }
                else if h.contains(t.lower) { g = 3 }
                else { continue }
                if g > hgrade { hgrade = g; bestHeading = hi }
            }
            if let bi = bestHeading, firstHeadingHit == nil {
                firstHeadingHit = (term: t, headingIndex: bi)
            }
            titleScore += grade
            headingScore += hgrade
            if scan.count == 0 && grade == 0 && hgrade == 0 { return nil }   // AND:缺一词即排除
            if scan.count > 0 { bodyScans.append((t, scan)) }
        }

        for (t, scan) in bodyScans {
            let weighted = isASCIIAlphanumeric(t.lower)
                ? Double(scan.wordCount * 2 + (scan.count - scan.wordCount))
                : Double(scan.count)
            var s = 1.0 + log(weighted)
            if let first = scan.firstRange, byteLen > 0 {
                // 首现字节偏移(UTF8View.Index == String.Index,整数编码,O(1))
                let byteOffset = doc.textLower.utf8.distance(
                    from: doc.textLower.utf8.startIndex, to: first.lowerBound)
                let x = Double(byteOffset) / byteLen
                s += 1.0 / (1.0 + log(1.0 + x))
            }
            bodyScore += s
        }
        let ratio = min(16.0, max(0.25, byteLen / avgLen))
        var score = bodyScore / sqrt(ratio) + titleScore + headingScore
        if terms.count > 1,
           doc.textLower.contains(phrase) || doc.titleLower.contains(phrase)
               || doc.headingsLower.contains(where: { $0.contains(phrase) }) {
            score *= 1.5   // 短语连续出现(整串含空格原样;小标题按单条判定)
        }

        // 摘要与偏移:正文命中 → 最稀有正文词(同词频取词序靠前)首现;
        // 全部词仅标题命中 → 首个标题命中词(与旧实现的标题摘要行为一致)
        if let rarest = bodyScans.min(by: { $0.scan.count < $1.scan.count }) {
            let offset = bodyOffset(rarest.term, rarest.scan, in: doc)
            return ScoredHit(score: score, hit: CHMSearchHit(
                path: doc.path, title: doc.title,
                snippet: CHMSnippet.around(offset, in: doc.text),
                offset: offset, isTitleMatch: anyTitle))
        }
        if let titleOff = firstTitleOffset {
            return ScoredHit(score: score, hit: CHMSearchHit(
                path: doc.path, title: doc.title,
                snippet: CHMSnippet.around(titleOff, in: doc.title),
                offset: titleOff, isTitleMatch: true))
        }
        if let hit = firstHeadingHit {
            // 全部词仅小标题命中:摘要取自命中的那条标题
            let raw = doc.headings[hit.headingIndex]
            let offset = headingOffset(hit.term,
                                       lower: doc.headingsLower[hit.headingIndex], raw: raw)
            return ScoredHit(score: score, hit: CHMSearchHit(
                path: doc.path, title: doc.title,
                snippet: CHMSnippet.around(offset, in: raw),
                offset: offset, isTitleMatch: anyTitle))
        }
        // 理论不可达(AND 要求每词至少一处命中):兜底
        return ScoredHit(score: score, hit: CHMSearchHit(
            path: doc.path, title: doc.title,
            snippet: CHMSnippet.around(0, in: doc.text),
            offset: 0, isTitleMatch: anyTitle))
    }

    /// 单条标题内首现偏移(对齐/回退规则同 bodyOffset)。
    private static func headingOffset(_ term: QueryTerm, lower: String, raw: String) -> Int {
        if raw.count == lower.count, let r = lower.range(of: term.lower) {
            return lower.distance(from: lower.startIndex, to: r.lowerBound)
        }
        if let r = raw.range(of: term.raw, options: .caseInsensitive) {
            return raw.distance(from: raw.startIndex, to: r.lowerBound)
        }
        return 0
    }

    /// 单词出现计数:单调推进的 range 搜索(非重叠);wordBoundary 时逐现检查整词。
    private static func scanTerm(
        _ term: String, in haystack: String, wordBoundary: Bool
    ) -> TermScan {
        var scan = TermScan()
        var search = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: term, range: search) {
            if scan.count == 0 { scan.firstRange = r }
            scan.count += 1
            if wordBoundary, isWordBounded(haystack, r) { scan.wordCount += 1 }
            search = r.upperBound..<haystack.endIndex
        }
        return scan
    }

    /// 区间前后均为非字母数字(整词出现)。
    private static func isWordBounded(_ s: String, _ r: Range<String.Index>) -> Bool {
        if r.lowerBound > s.startIndex {
            let prev = s[s.index(before: r.lowerBound)]
            if prev.isLetter || prev.isNumber { return false }
        }
        if r.upperBound < s.endIndex {
            let next = s[r.upperBound]
            if next.isLetter || next.isNumber { return false }
        }
        return true
    }

    /// 纯 ASCII 字母数字(启用整词统计;CJK 词跳过)。
    private static func isASCIIAlphanumeric(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                || ($0 >= 0x30 && $0 <= 0x39)
        }
    }

    /// 正文首现的字符偏移:textLower 与 text 字符数一致时直接对齐;
    /// 小写化改变字符数(如 İ)时回退原文大小写不敏感重查(与旧实现一致)。
    private static func bodyOffset(
        _ term: QueryTerm, _ scan: TermScan, in doc: CHMSearchDocument
    ) -> Int {
        if doc.text.count == doc.textLower.count, let first = scan.firstRange {
            return doc.textLower.distance(from: doc.textLower.startIndex, to: first.lowerBound)
        }
        if let r = doc.text.range(of: term.raw, options: .caseInsensitive) {
            return doc.text.distance(from: doc.text.startIndex, to: r.lowerBound)
        }
        return 0
    }

    /// 标题内首现偏移(对齐/回退规则同 bodyOffset)。
    private static func titleOffset(_ term: QueryTerm, in doc: CHMSearchDocument) -> Int {
        if doc.title.count == doc.titleLower.count,
           let r = doc.titleLower.range(of: term.lower) {
            return doc.titleLower.distance(from: doc.titleLower.startIndex, to: r.lowerBound)
        }
        if let r = doc.title.range(of: term.raw, options: .caseInsensitive) {
            return doc.title.distance(from: doc.title.startIndex, to: r.lowerBound)
        }
        return 0
    }

    // MARK: - 缓存

    /// 索引缓存格式版本:持久化结构变更(新增/改变字段,如 v2 的 headings
    /// 数组)时 +1,进入缓存键——旧缓存 URL 自然不再命中,下次搜索自动重建
    /// (书的 mtime 不变时也如此;否则旧缓存静默缺新信号且永不失效)。
    public static let cacheFormatVersion = 2

    /// 缓存键:路径|大小|mtime|v版本号(文件未变更时稳定;变更后自然失效)。
    /// public:AppModel 的隔离模式(CHIMERA_STATE_DIR)镜像同键算法。
    public static func cacheKey(for url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? Int ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(String(format: "%.0f", mtime))|v\(cacheFormatVersion)"
    }

    /// 缓存位置:键的 SHA256 → ~/Library/Caches/Chimera/<hash>.idx
    public static func cacheURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(cacheKey(for: url).utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chimera", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(digest).idx")
    }

    public func save(to url: URL) throws {
        let data = try PropertyListEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) -> CHMSearchIndex? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(CHMSearchIndex.self, from: data)
    }
}

/// 搜索命中。
public struct CHMSearchHit: Equatable, Sendable {
    public let path: String
    public let title: String
    public let snippet: String
    /// 命中起点偏移:正文命中时为正文纯文本中的字符偏移;仅标题命中时为标题内偏移
    /// (多词查询时为所选摘要词的首现偏移)。
    public let offset: Int
    /// 任一查询词命中标题即为 true(供 UI 展示标题命中标识)。
    public let isTitleMatch: Bool
}

/// 搜索结果:截断后的命中列表 + 未截断的总命中文档数。
public struct CHMSearchResults: Equatable, Sendable {
    /// 应用 limit 后的命中列表(标题命中优先,同级按文档顺序)。
    public let hits: [CHMSearchHit]
    /// 未应用 limit 前的总命中文档数。
    public let total: Int

    public init(hits: [CHMSearchHit], total: Int) {
        self.hits = hits
        self.total = total
    }
}
