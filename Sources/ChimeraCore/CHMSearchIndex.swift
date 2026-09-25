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

    /// HTML → 纯文本:移除 script/style 块,标签转空白,实体解码,空白折叠。
    public static func plainText(from html: String) -> String {
        var s = html
        for tag in ["script", "style"] {
            while let open = s.range(of: "<\(tag)", options: .caseInsensitive) {
                guard let close = s.range(of: "</\(tag)>", options: .caseInsensitive,
                                          range: open.upperBound..<s.endIndex) else {
                    s.removeSubrange(open.lowerBound..<s.endIndex)
                    break
                }
                s.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }

        var out = ""
        out.reserveCapacity(s.count)
        var inTag = false
        for ch in s {
            if ch == "<" {
                inTag = true
                out.append(" ")
            } else if ch == ">" {
                inTag = false
            } else if !inTag {
                out.append(ch)
            }
        }

        let decoded = CHMSitemapParser.decodeEntities(out)
        var collapsed = ""
        collapsed.reserveCapacity(decoded.count)
        var lastWasSpace = true
        for ch in decoded {
            if ch.isWhitespace {
                if !lastWasSpace {
                    collapsed.append(" ")
                    lastWasSpace = true
                }
            } else {
                collapsed.append(ch)
                lastWasSpace = false
            }
        }
        if collapsed.hasSuffix(" ") { collapsed.removeLast() }
        return collapsed
    }
}

// MARK: - 摘要

/// 命中上下文摘要。
public enum CHMSnippet {
    /// text 中 offset 处 ±radius 字符窗口;截断侧以 "…" 标记;折叠换行。
    public static func around(_ offset: Int, in text: String, radius: Int = 40) -> String {
        let chars = Array(text)
        guard !chars.isEmpty else { return "" }
        let clamped = min(max(offset, 0), chars.count - 1)
        let start = max(0, clamped - radius)
        let end = min(chars.count, clamped + 2 * radius)
        var s = String(chars[start..<end])
        if start > 0 { s = "…" + s }
        if end < chars.count { s += "…" }
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\r", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s
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
    /// 预计算的小写正文/标题:大小写折叠在构建/解码期只做一次,
    /// 搜索时走纯子串匹配(大书上比逐页 caseInsensitive 快一个量级)。
    /// 不随缓存持久化,解码时重算。
    let textLower: String
    let titleLower: String

    public init(path: String, title: String, text: String) {
        self.path = path
        self.title = title
        self.text = text
        self.textLower = text.lowercased()
        self.titleLower = title.lowercased()
    }

    private enum CodingKeys: String, CodingKey { case path, title, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try c.decode(String.self, forKey: .path),
            title: try c.decode(String.self, forKey: .title),
            text: try c.decode(String.self, forKey: .text)
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
        let info = try container.systemInfo()
        let entries = try container.allEntries().filter { entry in
            !entry.isDirectory
                && ["htm", "html"].contains((entry.path as NSString).pathExtension.lowercased())
        }

        var docs: [CHMSearchDocument] = []
        docs.reserveCapacity(entries.count)
        for (i, entry) in entries.enumerated() {
            if let data = try? container.read(entry.path) {
                let html = CHMTextDecoder.decode(data, lcid: info?.lcid)
                let bare = String(entry.path.dropFirst())
                let title = tocTitles[entry.path] ?? tocTitles[bare]
                    ?? CHMTextExtractor.title(from: html) ?? entry.path
                let text = CHMTextExtractor.plainText(from: html)
                if !text.isEmpty {
                    docs.append(CHMSearchDocument(path: entry.path, title: title, text: text))
                }
            }
            progress?(i + 1, entries.count)
        }
        return CHMSearchIndex(documents: docs)
    }

    /// 大小写不敏感子串搜索;等价于 `searchResults(query, limit:).hits`。
    public func search(_ query: String, limit: Int = 100) -> [CHMSearchHit] {
        searchResults(query, limit: limit).hits
    }

    /// 大小写不敏感子串搜索:标题命中优先于正文命中,同级按文档顺序;
    /// `total` 为未应用 limit 截断前的总命中文档数。
    public func searchResults(_ query: String, limit: Int = 100) -> CHMSearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return CHMSearchResults(hits: [], total: 0) }
        let ql = q.lowercased()
        // 每文档一个桶,并发搜索后按文档顺序合并(结果确定性;大书 ~4x 提速)
        var titleBuckets = [[CHMSearchHit]](repeating: [], count: documents.count)
        var bodyBuckets = [[CHMSearchHit]](repeating: [], count: documents.count)
        DispatchQueue.concurrentPerform(iterations: documents.count) { i in
            let doc = documents[i]
            let titleHit = doc.titleLower.contains(ql)
            let textRange = doc.textLower.range(of: ql)
            guard titleHit || textRange != nil else { return }
            let hit: CHMSearchHit
            if let r = textRange {
                // 小写化一般不改字符数,下标可直接对齐;不一致(如 İ)时回退原文重查
                let offset: Int
                if doc.text.count == doc.textLower.count {
                    offset = doc.textLower.distance(from: doc.textLower.startIndex, to: r.lowerBound)
                } else if let r2 = doc.text.range(of: q, options: .caseInsensitive) {
                    offset = doc.text.distance(from: doc.text.startIndex, to: r2.lowerBound)
                } else {
                    return
                }
                hit = CHMSearchHit(
                    path: doc.path,
                    title: doc.title,
                    snippet: CHMSnippet.around(offset, in: doc.text),
                    offset: offset,
                    isTitleMatch: titleHit
                )
            } else {
                // 仅标题命中:摘要与偏移取自标题
                let offset: Int
                if doc.title.count == doc.titleLower.count,
                   let r = doc.titleLower.range(of: ql) {
                    offset = doc.titleLower.distance(from: doc.titleLower.startIndex, to: r.lowerBound)
                } else if let r = doc.title.range(of: q, options: .caseInsensitive) {
                    offset = doc.title.distance(from: doc.title.startIndex, to: r.lowerBound)
                } else {
                    offset = 0
                }
                hit = CHMSearchHit(
                    path: doc.path,
                    title: doc.title,
                    snippet: CHMSnippet.around(offset, in: doc.title),
                    offset: offset,
                    isTitleMatch: true
                )
            }
            if titleHit { titleBuckets[i] = [hit] } else { bodyBuckets[i] = [hit] }
        }
        let all = titleBuckets.flatMap { $0 } + bodyBuckets.flatMap { $0 }
        return CHMSearchResults(hits: Array(all.prefix(limit)), total: all.count)
    }

    // MARK: - 缓存

    /// 缓存键:文件路径+大小+mtime 的 SHA256 → ~/Library/Caches/Chimera/<hash>.idx
    /// (文件未变更时键稳定;变更后自然失效)。
    public static func cacheURL(for url: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? Int ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(size)|\(String(format: "%.0f", mtime))"
        let digest = SHA256.hash(data: Data(key.utf8))
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
    /// 命中起点偏移:正文命中时为正文纯文本中的字符偏移;仅标题命中时为标题内偏移。
    public let offset: Int
    /// 标题是否命中(标题命中的结果排在正文命中之前)。
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
