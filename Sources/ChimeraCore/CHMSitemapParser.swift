import Foundation

/// CHM 目录树(.hhc)节点。
public struct CHMTocItem: Equatable, Sendable {
    /// 显示标题(Name 参数)。
    public var title: String
    /// 目标内部路径(Local 参数,首个;文件夹节点可能没有)。
    public var local: String?
    /// 合并的外部 sitemap(Merge 参数)。
    public var merge: String?
    /// 子节点(由 <UL> 嵌套产生)。
    public var children: [CHMTocItem]

    public init(title: String, local: String? = nil, merge: String? = nil, children: [CHMTocItem] = []) {
        self.title = title
        self.local = local
        self.merge = merge
        self.children = children
    }
}

/// CHM 索引(.hhk)条目。
public struct CHMIndexEntry: Equatable, Sendable {
    /// 索引词条(Keyword 参数,缺省退回 Name)。
    public var keyword: String
    /// 目标内部路径(一个词条可挂多个 Local)。
    public var targets: [String]

    public init(keyword: String, targets: [String]) {
        self.keyword = keyword
        self.targets = targets
    }
}

/// 解析 HTML Help sitemap(.hhc 目录 / .hhk 索引)。
/// 这类文件不是合法 XML(大小写混杂、可省闭合标签、含注释),
/// 因此采用容错的自定义标签扫描而非 XML 解析器。
public enum CHMSitemapParser {

    // MARK: - 公开 API

    /// 解析 .hhc → 目录树。
    public static func parseTOC(_ html: String) -> [CHMTocItem] {
        mapOut(parseTree(html))
    }

    /// 解析 .hhk → 扁平索引列表(嵌套词条按深度优先展开)。
    public static func parseIndex(_ html: String) -> [CHMIndexEntry] {
        var out: [CHMIndexEntry] = []
        func walk(_ nodes: [Node]) {
            for n in nodes {
                out.append(CHMIndexEntry(keyword: n.keyword ?? n.name ?? "", targets: n.locals))
                walk(n.children)
            }
        }
        walk(parseTree(html))
        return out.filter { !$0.keyword.isEmpty || !$0.targets.isEmpty }
    }

    // MARK: - 内部

    /// 通用节点(Name/Keyword/多 Local/Merge 全保留)。
    private struct Node {
        var name: String?
        var keyword: String?
        var locals: [String] = []
        var merge: String?
        var children: [Node] = []
        var isEmpty: Bool { name == nil && keyword == nil && locals.isEmpty && merge == nil }
    }

    private static func mapOut(_ nodes: [Node]) -> [CHMTocItem] {
        nodes.map {
            CHMTocItem(
                title: $0.name ?? $0.keyword ?? "",
                local: $0.locals.first,
                merge: $0.merge,
                children: mapOut($0.children)
            )
        }
    }

    /// 扫描 <UL>/<LI>/<OBJECT>/<param>,构建节点树。
    /// 语义:<UL> 开新层,层内条目在 </UL> 时挂到上一层的最后一个节点之下。
    private static func parseTree(_ html: String) -> [Node] {
        var roots: [Node] = []
        var stack: [[Node]] = [[]]
        var acc = Node()
        var inObject = false

        func flush() {
            guard inObject || !acc.isEmpty else { return }
            if !acc.isEmpty {
                stack[stack.count - 1].append(acc)
            }
            acc = Node()
            inObject = false
        }

        func closeUL() {
            let level = stack.popLast() ?? []
            if !stack.isEmpty {
                if var last = stack[stack.count - 1].popLast() {
                    last.children += level
                    stack[stack.count - 1].append(last)
                } else {
                    stack[stack.count - 1] += level
                }
            } else {
                roots += level
            }
        }

        var i = html.startIndex
        while let lt = html[i...].firstIndex(of: "<") {
            // 注释整段跳过
            if html[lt...].hasPrefix("<!--") {
                guard let end = html[lt...].range(of: "-->") else { break }
                i = end.upperBound
                continue
            }
            guard let gt = html[lt...].firstIndex(of: ">") else { break }
            let tag = String(html[html.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            i = html.index(after: gt)
            let lower = tag.lowercased()

            if lower == "ul" || lower.hasPrefix("ul ") {
                flush()
                stack.append([])
            } else if lower == "/ul" || lower.hasPrefix("/ul ") {
                flush()
                closeUL()
            } else if lower == "li" || lower.hasPrefix("li ") {
                // HHC 常省略 </OBJECT>,新的 <LI> 即上一项结束
                flush()
            } else if lower == "object" || lower.hasPrefix("object ") {
                flush()
                inObject = true
            } else if lower == "/object" || lower.hasPrefix("/object ") {
                flush()
            } else if lower == "param" || lower.hasPrefix("param ") {
                let attrs = attributes(of: tag)
                if let n = attrs["name"]?.lowercased(), let v = attrs["value"] {
                    switch n {
                    case "name": if acc.name == nil { acc.name = decodeEntities(v) }
                    case "keyword": acc.keyword = decodeEntities(v)
                    case "local": acc.locals.append(decodeEntities(v))
                    case "merge": if acc.merge == nil { acc.merge = decodeEntities(v) }
                    default: break
                    }
                }
            }
        }
        flush()
        while stack.count > 1 { closeUL() }  // 未闭合 <UL> 兜底
        roots += stack.first ?? []
        return roots
    }

    /// 提取标签属性(双引号/单引号/无引号),键小写。
    private static func attributes(of tag: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = tag.startIndex
        while i < tag.endIndex {
            while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
            guard i < tag.endIndex else { break }
            let keyStart = i
            while i < tag.endIndex, !tag[i].isWhitespace, tag[i] != "=" { i = tag.index(after: i) }
            let key = String(tag[keyStart..<i]).lowercased()
            while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
            guard i < tag.endIndex, tag[i] == "=" else { continue }
            i = tag.index(after: i)
            while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
            guard i < tag.endIndex else { break }
            let quote = tag[i]
            let value: String
            if quote == "\"" || quote == "'" {
                i = tag.index(after: i)
                let vStart = i
                while i < tag.endIndex, tag[i] != quote { i = tag.index(after: i) }
                value = String(tag[vStart..<i])
                if i < tag.endIndex { i = tag.index(after: i) }
            } else {
                let vStart = i
                while i < tag.endIndex, !tag[i].isWhitespace { i = tag.index(after: i) }
                value = String(tag[vStart..<i])
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    /// 最小 HTML 实体解码:十进制/十六进制数字实体 + 常用具名实体。
    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&",
               let semi = s[i...].firstIndex(of: ";"),
               semi <= s.index(i, offsetBy: 11) {
                let ent = String(s[s.index(after: i)..<semi]).lowercased()
                if ent.hasPrefix("#x"), let code = UInt32(ent.dropFirst(2), radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    out.unicodeScalars.append(scalar)
                    i = s.index(after: semi)
                    continue
                }
                if ent.hasPrefix("#"), let code = UInt32(ent.dropFirst()),
                   let scalar = Unicode.Scalar(code) {
                    out.unicodeScalars.append(scalar)
                    i = s.index(after: semi)
                    continue
                }
                if let c = named[ent] {
                    out.append(c)
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
