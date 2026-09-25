import Testing
import Foundation
@testable import ChimeraCore

private let benchmarkPath =
    NSString(string: "~/Downloads/5R不全书（全扩展）2026.9.13.chm").expandingTildeInPath

// MARK: - 文本抽取

@Test func extractsTitleAndPlainText() {
    let html = """
    <html><head><title>法术 &amp; 技能</title>
    <style>.x{color:red}</style></head>
    <body><h1>标题一</h1><script>var a=1;</script>
    <p>这是&nbsp;正文内容。</p></body></html>
    """
    #expect(CHMTextExtractor.title(from: html) == "法术 & 技能")
    let plain = CHMTextExtractor.plainText(from: html)
    #expect(plain.contains("标题一"))
    #expect(plain.contains("正文内容"))
    #expect(!plain.contains("color:red"), "style 块应整体移除")
    #expect(!plain.contains("var a=1"), "script 块应整体移除")
    #expect(!plain.contains("<"), "标签应全部移除")
    #expect(!plain.contains("\u{00A0}"), "实体解码后空白应折叠")
}

// MARK: - 摘要

@Test func snippetAroundHit() {
    let text = String(repeating: "甲", count: 60) + "命中词" + String(repeating: "乙", count: 60)
    let offset = text.distance(from: text.startIndex, to: text.firstIndex(of: "命")!)
    let s = CHMSnippet.around(offset, in: text, radius: 10)
    #expect(s.contains("命中词"))
    #expect(s.hasPrefix("…"), "前截断应带省略号")
    #expect(s.hasSuffix("…"), "后截断应带省略号")
    #expect(s.count < 40, "摘要应短于窗口上限")
    // 边界:offset 在开头,不应有前省略号
    let s2 = CHMSnippet.around(0, in: text, radius: 10)
    #expect(!s2.hasPrefix("…"))
}

// MARK: - 搜索

@Test func searchFindsDocuments() {
    let docs = [
        CHMSearchDocument(path: "/a.htm", title: "A", text: "这里有 法术 说明"),
        CHMSearchDocument(path: "/b.htm", title: "B", text: "法术列表\n第二行"),
        CHMSearchDocument(path: "/c.htm", title: "C", text: "无关内容"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    let hits = idx.search("法术")
    #expect(hits.count == 2)
    #expect(hits.map(\.path).contains("/a.htm"))
    #expect(!hits.map(\.path).contains("/c.htm"))
    let b = hits.first { $0.path == "/b.htm" }
    #expect(b?.snippet.contains("法术列表") == true, "摘要应含命中上下文")
    #expect(b?.offset ?? -1 >= 0)

    // 大小写不敏感
    let idx2 = CHMSearchIndex(documents: [
        CHMSearchDocument(path: "/e.htm", title: "E", text: "DnD 检定 DND"),
    ])
    #expect(idx2.search("dnd").count == 1)

    // 空查询/纯空白
    #expect(idx.search("   ").isEmpty)
    // limit 生效
    let many = CHMSearchIndex(documents: (0..<50).map {
        CHMSearchDocument(path: "/p\($0).htm", title: "P", text: "命中")
    })
    #expect(many.search("命中", limit: 10).count == 10)
}

// MARK: - 缓存

@Test func cacheRoundtripAndStableKey() throws {
    let docs = [
        CHMSearchDocument(path: "/a.htm", title: "A", text: "法术内容"),
        CHMSearchDocument(path: "/b.htm", title: "B", text: "其他"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chimera-test-\(UUID().uuidString).idx")
    defer { try? FileManager.default.removeItem(at: url) }

    try idx.save(to: url)
    let loaded = try #require(try CHMSearchIndex.load(from: url))
    #expect(loaded.documents.count == docs.count)
    #expect(loaded.search("法术").count == idx.search("法术").count)
    #expect(CHMSearchIndex.load(from: url.appendingPathComponent("nope")) == nil)

    // 同一文件(未变更)应得到稳定缓存键
    let bench = URL(fileURLWithPath: benchmarkPath)
    if FileManager.default.fileExists(atPath: benchmarkPath) {
        #expect(CHMSearchIndex.cacheURL(for: bench) == CHMSearchIndex.cacheURL(for: bench))
    }
}

// MARK: - 基准集成(记录耗时)

@Test func buildsIndexFromBenchmark() throws {
    try #require(FileManager.default.fileExists(atPath: benchmarkPath), "基准文件缺失")
    let c = try CHMContainer(path: benchmarkPath)
    let started = Date()
    let idx = try CHMSearchIndex.build(container: c)
    let elapsed = Date().timeIntervalSince(started)
    print("BENCH index build: \(idx.documents.count) docs in \(String(format: "%.2f", elapsed))s")
    #expect(idx.documents.count > 100, "应索引超过 100 个页面")

    let hits = idx.search("法术")
    #expect(!hits.isEmpty, "搜索 法术 应有命中")
    #expect(hits.allSatisfy { !$0.title.isEmpty })

    // 缓存保存/加载(真实路径)
    let cache = CHMSearchIndex.cacheURL(for: URL(fileURLWithPath: benchmarkPath))
    defer { try? FileManager.default.removeItem(at: cache) }
    try idx.save(to: cache)
    let loaded = try #require(try CHMSearchIndex.load(from: cache))
    #expect(loaded.documents.count == idx.documents.count)
}
