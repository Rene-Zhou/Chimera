import Testing
import Foundation
@testable import ChimeraCore

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

@Test func plainTextHandlesMultiScriptStyleAndEntityLiteral() {
    // 多 script/style 块(含大写开标签)+ 不闭合 script + 文本内 &lt;script&gt; 字面量:
    // 实体解码在标签移除之后,解出的 "<script>" 是文本,不得再按块剥离
    let html = """
    <html><head><style>.a{color:red}</style><STYLE>.b{font:2px}</STYLE></head>
    <body>
    <p>实体 &lt;script&gt; 保持为文本</p>
    <script type="text/javascript">var x=1;</script>
    <p>第二段</p>
    <style>body{margin:0}</style>
    <script>var y=2;
    <p>被丢弃</p></body></html>
    """
    let plain = CHMTextExtractor.plainText(from: html)
    #expect(plain == "实体 <script> 保持为文本 第二段")
    #expect(!plain.contains("color:red") && !plain.contains("font:2px")
            && !plain.contains("margin:0"), "style 块应整体移除")
    #expect(!plain.contains("var x") && !plain.contains("var y"), "script 内容应移除")
    #expect(!plain.contains("被丢弃"), "不闭合 script 之后的内容应一并丢弃")
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

@Test func snippetWindowsOnVeryLongText() {
    // >100k 字符长文本:窗口定位不得依赖整页拷贝;头/中/尾三处偏移逐一验证
    let prefix = String(repeating: "甲", count: 100_000)
    let suffix = String(repeating: "乙", count: 100_000)
    let text = prefix + "目标" + suffix
    let markerOffset = 100_000 // "目" 的字符偏移

    // 头部:无前省略号,窗口 [0, 2r)
    let head = CHMSnippet.around(0, in: text, radius: 10)
    #expect(head == String(repeating: "甲", count: 20) + "…")

    // 中部:双侧省略号,窗口 [o-r, o+2r) = 10 甲 + 目标 + 18 乙
    let mid = CHMSnippet.around(markerOffset, in: text, radius: 10)
    #expect(mid == "…" + String(repeating: "甲", count: 10) + "目标"
        + String(repeating: "乙", count: 18) + "…")
    #expect(mid.count <= 3 * 10 + 2, "摘要长度应受窗口上限约束")

    // 尾部:无后省略号;越界偏移钳制到最后一字符
    let tail = CHMSnippet.around(text.count - 1, in: text, radius: 10)
    #expect(tail == "…" + String(repeating: "乙", count: 11))
    #expect(CHMSnippet.around(text.count + 500, in: text, radius: 10) == tail)

    // 长文本中混排空白:换行/回车折叠为空格,连续空格合并为一个
    let messy = String(repeating: "丙", count: 200_000) + "A  B\nC\r D"
        + String(repeating: "丁", count: 200_000)
    let m = CHMSnippet.around(200_002, in: messy, radius: 12)
    #expect(m.contains("A B C D"))
    #expect(!m.contains("  ") && !m.contains("\n") && !m.contains("\r"))
}

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

@Test func searchRanksTitleMatchesFirst() {
    let docs = [
        CHMSearchDocument(path: "/a.htm", title: "无标题命中", text: "这里有法术说明"),
        CHMSearchDocument(path: "/b.htm", title: "法术大全", text: "无关正文"),
        CHMSearchDocument(path: "/c.htm", title: "其他", text: "正文也有法术"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    let results = idx.searchResults("法术")
    // 仅标题命中的 /b.htm 也应计入结果,且标题命中排在正文命中之前
    #expect(results.total == 3)
    #expect(results.hits.map(\.path) == ["/b.htm", "/a.htm", "/c.htm"])
    #expect(results.hits[0].isTitleMatch)
    #expect(results.hits[0].snippet.contains("法术大全"), "仅标题命中时摘要取自标题")
    #expect(!results.hits[1].isTitleMatch)
    // 旧 API 兼容:search 返回 hits 部分
    #expect(idx.search("法术").map(\.path) == results.hits.map(\.path))
}

@Test func searchReportsTotalBeyondLimit() {
    let many = CHMSearchIndex(documents: (0..<50).map {
        CHMSearchDocument(path: "/p\($0).htm", title: "P", text: "命中")
    })
    let results = many.searchResults("命中", limit: 10)
    #expect(results.hits.count == 10)
    #expect(results.total == 50, "limit 截断不影响 total")
    // 空查询:total 为 0
    #expect(many.searchResults("   ").total == 0)
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
    if benchmarkCHMExists {
        let bench = URL(fileURLWithPath: benchmarkCHMPath)
        #expect(CHMSearchIndex.cacheURL(for: bench) == CHMSearchIndex.cacheURL(for: bench))
    }
}

// MARK: - 基准集成(记录耗时)

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func buildWithProvidedEntriesMatchesSubset() throws {
    // 廉价等价性:传入条目子集构建,产出应是子集内的非空文本文档
    let c = try CHMContainer(path: benchmarkCHMPath)
    let all = try c.allEntries()
    let html = all.filter {
        !$0.isDirectory && ["htm", "html"].contains(($0.path as NSString).pathExtension.lowercased())
    }
    let subset = Array(html.prefix(30))
    let subsetPaths = Set(subset.map(\.path))
    let idx = try CHMSearchIndex.build(container: c, entries: subset)
    #expect(!idx.documents.isEmpty)
    #expect(idx.documents.allSatisfy { subsetPaths.contains($0.path) },
            "entries 重载不应索引子集之外的页面")
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func buildSortedByPhysicalOffsetMatchesLegacyDocumentSet() throws {
    // P0-4 验收:entries 重载按物理偏移排序后,产出文档集合与旧签名一致(仅顺序不同)
    let c = try CHMContainer(path: benchmarkCHMPath)
    let all = try c.allEntries()
    let legacy = try CHMSearchIndex.build(container: c)
    let provided = try CHMSearchIndex.build(container: c, entries: all)
    #expect(Set(legacy.documents.map(\.path)) == Set(provided.documents.map(\.path)),
            "排序读取不应改变索引的文档集合")
    #expect(legacy.documents.count == provided.documents.count)

    // 文档应按条目 start 升序排列(与 allEntries 的目录序不同)
    let startByPath = Dictionary(all.map { ($0.path, $0.start) },
                                 uniquingKeysWith: { a, _ in a })
    let starts = provided.documents.compactMap { startByPath[$0.path] }
    #expect(starts.count == provided.documents.count)
    #expect(starts == starts.sorted(), "documents 应按物理偏移升序排列")
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func buildCountsFailedPagesWithoutAborting() throws {
    // P2-12 验收:伪造条目(未压缩空间 + 超出文件尾的 start)读取必抛错;
    // 构建应记录失败页并继续完成其余页面
    let c = try CHMContainer(path: benchmarkCHMPath)
    let html = try c.allEntries().filter {
        !$0.isDirectory && ["htm", "html"].contains(($0.path as NSString).pathExtension.lowercased())
    }
    let real = Array(html.prefix(5))
    let ghost = CHMEntry(path: "/__ghost__.htm", length: 16, isDirectory: false,
                         space: 0, start: UInt64(1) << 40)
    var failed: [String] = []
    let idx = try CHMSearchIndex.build(container: c, entries: real + [ghost]) { path in
        failed.append(path)
    }
    #expect(failed == ["/__ghost__.htm"], "失败页应恰好被计数一次,实际 \(failed)")
    #expect(!idx.documents.contains { $0.path == "/__ghost__.htm" }, "失败页不得进入索引")
    #expect(!idx.documents.isEmpty, "其余页面应正常构建,不得中断")

    let clean = try CHMSearchIndex.build(container: c, entries: real)
    #expect(Set(idx.documents.map(\.path)) == Set(clean.documents.map(\.path)),
            "混入失败页不应影响其余文档产出")
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func benchmarkSortedVsDirectoryOrderReads() throws {
    // P0-4 诊断基准(仅打印,不作硬断言):同样的页面集合,
    // 目录序 + 默认块缓存 + 按路径读取 vs 物理序 + 128 块缓存 + 零 resolve 读取
    let c = try CHMContainer(path: benchmarkCHMPath)
    let html = try c.allEntries().filter {
        !$0.isDirectory && ["htm", "html"].contains(($0.path as NSString).pathExtension.lowercased())
    }

    var t = Date()
    var bytes = 0
    for e in html { bytes += (try? c.read(e.path))?.count ?? 0 }
    let legacy = Date().timeIntervalSince(t)

    let sorted = html.sorted { $0.start != $1.start ? $0.start < $1.start : $0.path < $1.path }
    let c2 = try CHMContainer(path: benchmarkCHMPath)
    c2.setCacheBlockCount(128)
    t = Date()
    var bytes2 = 0
    for e in sorted { bytes2 += (try? c2.read(entry: e))?.count ?? 0 }
    let physical = Date().timeIntervalSince(t)

    #expect(bytes == bytes2, "两种读取方式总字节应一致")
    print("BENCH reads \(html.count) pages: directory-order \(String(format: "%.2f", legacy))s "
        + "vs physical-order+cache128 \(String(format: "%.2f", physical))s")
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func buildsIndexFromBenchmark() throws {
    let c = try CHMContainer(path: benchmarkCHMPath)
    let started = Date()
    let idx = try CHMSearchIndex.build(container: c)
    let elapsed = Date().timeIntervalSince(started)
    print("BENCH index build: \(idx.documents.count) docs in \(String(format: "%.2f", elapsed))s")
    #expect(idx.documents.count > 100, "应索引超过 100 个页面")

    let hits = idx.search("法术")
    #expect(!hits.isEmpty, "搜索 法术 应有命中")
    #expect(hits.allSatisfy { !$0.title.isEmpty })

    // 缓存保存/加载(真实路径)
    let cache = CHMSearchIndex.cacheURL(for: URL(fileURLWithPath: benchmarkCHMPath))
    defer { try? FileManager.default.removeItem(at: cache) }
    try idx.save(to: cache)
    let loaded = try #require(try CHMSearchIndex.load(from: cache))
    #expect(loaded.documents.count == idx.documents.count)
}
