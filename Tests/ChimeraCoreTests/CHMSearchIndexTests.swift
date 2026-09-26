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

@Test func searchRanksTitleMatchesFirst() throws {
    let docs = [
        CHMSearchDocument(path: "/a.htm", title: "无标题命中", text: "这里有法术说明"),
        CHMSearchDocument(path: "/b.htm", title: "法术大全", text: "无关正文"),
        CHMSearchDocument(path: "/c.htm", title: "其他", text: "正文也有法术"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    let results = idx.searchResults("法术")
    // 相关度排序:标题分级 b(前缀 ×5)居首;正文两页按密度×首现位置排——
    // c 更短更密(1.62) > a(1.56),与旧的文档顺序相反
    #expect(results.total == 3)
    #expect(results.hits.map(\.path) == ["/b.htm", "/c.htm", "/a.htm"])
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

// MARK: - 相关度重排序(多词 AND + 词频/密度/标题分级/整词边界/短语加权)

@Test func searchRanksByTermFrequency() throws {
    // 同量级文档:提及 3 次 > 1 次(词频饱和 1+ln(tf))
    let docs = [
        CHMSearchDocument(path: "/once.htm", title: "T1", text: "介绍 法术 的一次提及"),
        CHMSearchDocument(path: "/triple.htm", title: "T2", text: "法术、法术与法术的多次提及"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    let first = try #require(idx.searchResults("法术").hits.first)
    #expect(first.path == "/triple.htm")
}

@Test func searchPrefersDenseShortPage() throws {
    // 密度归一:3 次提及的超长页 < 1 次提及的短页(同频次短页优先的推广)
    let long = String(repeating: "填充", count: 2000) + " 法术 段落一 "
        + String(repeating: "内容", count: 2000) + " 法术 段落二 "
        + String(repeating: "补充", count: 1000) + " 法术 段落三"
    let short = "法术 简短说明"
    let docs = [
        CHMSearchDocument(path: "/long.htm", title: "L", text: long),
        CHMSearchDocument(path: "/short.htm", title: "S", text: short),
    ]
    let idx = CHMSearchIndex(documents: docs)
    let first = try #require(idx.searchResults("法术").hits.first)
    #expect(first.path == "/short.htm")
}

@Test func searchTitleGradingExactPrefixContains() throws {
    // 标题分级:精确(×8) > 前缀(×5) > 包含(×2) > 仅正文;文档故意逆序放入
    let docs = [
        CHMSearchDocument(path: "/contains.htm", title: "大全法术目录", text: "完全无关的内容三"),
        CHMSearchDocument(path: "/prefix.htm", title: "法术大全", text: "完全无关的内容二"),
        CHMSearchDocument(path: "/body.htm", title: "其他", text: "前言 法术 介绍与说明"),
        CHMSearchDocument(path: "/exact.htm", title: "法术", text: "完全无关的内容一"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    #expect(idx.searchResults("法术").hits.map(\.path)
        == ["/exact.htm", "/prefix.htm", "/contains.htm", "/body.htm"])
}

@Test func searchMultiTermANDSemantics() throws {
    // 多词 AND:全部词命中(正文或标题)才入选;零结果不回退 OR
    let docs = [
        CHMSearchDocument(path: "/both.htm", title: "两词", text: "火球是法术的一种"),
        CHMSearchDocument(path: "/only1.htm", title: "单词", text: "只有法术的页面"),
        CHMSearchDocument(path: "/only2.htm", title: "单词二", text: "只有火球的页面"),
        CHMSearchDocument(path: "/title2.htm", title: "火球列表", text: "各种法术的介绍"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    let r = idx.searchResults("火球 法术")
    #expect(Set(r.hits.map(\.path)) == ["/both.htm", "/title2.htm"])
    #expect(r.total == 2)
    // 火球仅标题命中:AND 由标题满足,isTitleMatch 为真
    let t2 = try #require(r.hits.first { $0.path == "/title2.htm" })
    #expect(t2.isTitleMatch)
    // 任一词不存在 → 零结果,不得回退 OR
    #expect(idx.searchResults("法术 完全不存在的词").total == 0)
}

@Test func searchPhraseBoostRanksContiguousFirst() throws {
    // 短语加权:整串连续出现(含空格原样)×1.5,胜过同词频的分散出现
    let docs = [
        CHMSearchDocument(path: "/apart.htm", title: "T",
                          text: "火球 开场介绍隔开较多文字内容 法术 各自出现一次的页面"),
        CHMSearchDocument(path: "/adjacent.htm", title: "T",
                          text: "介绍 火球 法术 连续出现的页面文字内容较多填充"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    let first = try #require(idx.searchResults("火球 法术").hits.first)
    #expect(first.path == "/adjacent.htm")
}

@Test func searchDedupesRepeatedQueryTerms() {
    // 重复词去重:"法术 法术" 与单词查询结果完全一致
    let docs = [
        CHMSearchDocument(path: "/a.htm", title: "A", text: "法术说明"),
        CHMSearchDocument(path: "/b.htm", title: "法术列表", text: "无关"),
        CHMSearchDocument(path: "/c.htm", title: "C", text: "法术、法术与法术"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    #expect(idx.searchResults("法术 法术").hits.map(\.path)
        == idx.searchResults("法术").hits.map(\.path))
    #expect(idx.searchResults("法术 法术").total == idx.searchResults("法术").total)
}

@Test func searchASCIIWholeWordOutranksSubstring() throws {
    // ASCII 词边界:整词 "art" ×3 胜过等次数纯子串 "start" 里的 art
    let docs = [
        CHMSearchDocument(path: "/substr.htm", title: "T", text: "start start start of motion"),
        CHMSearchDocument(path: "/whole.htm", title: "T", text: "art art art of combat"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    let first = try #require(idx.searchResults("art").hits.first)
    #expect(first.path == "/whole.htm")
}

@Test func searchSnippetUsesRarestTerm() throws {
    // 多词摘要:取该文档内命中次数最少的词(信息量最大)的首现窗口
    let text = "法术一 法术二 法术三 法术四 法术五 中段介绍 罕见词 仅此一次 结尾说明"
    let idx = CHMSearchIndex(documents: [
        CHMSearchDocument(path: "/p.htm", title: "T", text: text),
    ])
    let hit = try #require(idx.searchResults("法术 罕见词").hits.first)
    let expected = text.distance(from: text.startIndex,
                                 to: text.range(of: "罕见词")!.lowerBound)
    #expect(hit.offset == expected, "偏移应指向最稀有词首现,实际 \(hit.offset)")
    #expect(hit.snippet.contains("罕见词"))
}

@Test func searchSingleTermResultSetMatchesSubstringSemantics() {
    // 回归锁:单词查询的命中文档集合与"标题或正文包含"的子串语义逐一相等(排序可变)
    let docs = [
        CHMSearchDocument(path: "/a.htm", title: "法术大全", text: "无关一"),
        CHMSearchDocument(path: "/b.htm", title: "其他", text: "正文含 DnD 检定"),
        CHMSearchDocument(path: "/c.htm", title: "C", text: "完全无关"),
        CHMSearchDocument(path: "/d.htm", title: "DND 手册", text: "正文 dnd 也出现"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    for q in ["法术", "dnd", "DnD"] {
        let expected = Set(docs.filter {
            $0.title.lowercased().contains(q.lowercased())
                || $0.text.lowercased().contains(q.lowercased())
        }.map(\.path))
        let r = idx.searchResults(q)
        #expect(r.total == expected.count, "查询 \(q): total \(r.total) 应为 \(expected.count)")
        #expect(Set(r.hits.map(\.path)) == expected)
    }
}

// MARK: - 小标题(h1~h6)抽取与加权

@Test func headingTextExtractsH1ToH6() {
    // 基本:h1~h6 全档、大小写不敏感、内层标签→空格、片段空格拼接
    let html = """
    <html><head><title>页题</title></head>
    <body><h1>第一章</h1><p>正文一</p>
    <H2>火球 <b>术</b>的说明</H2><p>正文二</p>
    <h3>附注</h3></body></html>
    """
    #expect(CHMTextExtractor.headingText(from: html) == "第一章 火球 术 的说明 附注")
}

@Test func headingTextHandlesUnclosedAndSkipsNonHeadingTags() {
    // 不闭合:取到下一个标题开标签;head/hr/h7 不算标题
    let unclosed = "<h2>未闭合<h3>第二个</h3>尾部<h4>第三</h4>"
    #expect(CHMTextExtractor.headingText(from: unclosed) == "未闭合 第二个 第三")
    let nonHeading = "<html><head><meta></head><body><hr><h7>伪标题</h7><h2>真标题</h2></body></html>"
    #expect(CHMTextExtractor.headingText(from: nonHeading) == "真标题")
    // 无标题 → 空串
    #expect(CHMTextExtractor.headingText(from: "<p>没有标题的正文</p>") == "")
    // 自闭合 <h2/> 不吞噬后续内容
    let selfClosed = "<h2/><p>正文</p><h3>真标题</h3>"
    #expect(CHMTextExtractor.headingText(from: selfClosed) == "真标题")
}

@Test func searchHeadingMatchOutranksBodyMention() throws {
    // 小标题命中(×3)应胜过正文单次提及(≈1.8);摘要取自小标题;isTitleMatch 为假
    let docs = [
        CHMSearchDocument(path: "/body.htm", title: "T", text: "介绍与火球的正文内容"),
        CHMSearchDocument(path: "/heading.htm", title: "T", text: "介绍与说明的正文内容",
                          headings: "火球术 施法者指南"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    let first = try #require(idx.searchResults("火球").hits.first)
    #expect(first.path == "/heading.htm")
    #expect(first.snippet.contains("火球术"), "仅小标题命中时摘要取自小标题")
    #expect(!first.isTitleMatch)
}

@Test func searchHeadingGradingExactPrefixContains() throws {
    // 小标题分级:== ×5 / 前缀 ×4 / 包含 ×3(介于标题与正文之间)
    let docs = [
        CHMSearchDocument(path: "/contains.htm", title: "T", text: "正文丙", headings: "介绍火球与说明"),
        CHMSearchDocument(path: "/exact.htm", title: "T", text: "正文甲", headings: "火球"),
        CHMSearchDocument(path: "/prefix.htm", title: "T", text: "正文乙", headings: "火球大全"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    #expect(idx.searchResults("火球").hits.map(\.path)
        == ["/exact.htm", "/prefix.htm", "/contains.htm"])
}

@Test func searchTitleExactStillBeatsHeadingExact() throws {
    // 页面标题精确(×8)仍高于小标题精确(×5)
    let docs = [
        CHMSearchDocument(path: "/heading.htm", title: "其他", text: "正文一", headings: "火球"),
        CHMSearchDocument(path: "/title.htm", title: "火球", text: "正文二", headings: "无关"),
    ]
    let idx = CHMSearchIndex(documents: docs)
    #expect(idx.searchResults("火球").hits.first?.path == "/title.htm")
}

@Test func headingFieldBackwardCompatibleWithOldCache() throws {
    // 旧缓存缺 headings 键:解码为空,搜索照常(无小标题信号,重建后生效)
    let dict: [String: Any] = ["path": "/a.htm", "title": "A", "text": "法术内容"]
    let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    let doc = try PropertyListDecoder().decode(CHMSearchDocument.self, from: data)
    #expect(doc.headings == "")
    #expect(doc.headingsLower == "")
    #expect(doc.titleLower == "a", "小写预计算应在解码时重算")
    // 新格式往返:headings 保留
    let fresh = CHMSearchDocument(path: "/h.htm", title: "T", text: "正文", headings: "甲 乙")
    let roundtrip = try PropertyListDecoder().decode(
        CHMSearchDocument.self, from: PropertyListEncoder().encode(fresh))
    #expect(roundtrip.headings == "甲 乙")
    #expect(roundtrip.headingsLower == "甲 乙")
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

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func builtIndexContainsHeadingSignal() throws {
    // 构建 wiring:真实 CHM 页面应抽到非空小标题信号
    let c = try CHMContainer(path: benchmarkCHMPath)
    let htmlEntries = try c.allEntries().filter {
        !$0.isDirectory && ["htm", "html"].contains(($0.path as NSString).pathExtension.lowercased())
    }
    let idx = try CHMSearchIndex.build(container: c, entries: Array(htmlEntries.prefix(500)))
    let withHeadings = idx.documents.filter { !$0.headings.isEmpty }
    print("HEADINGS signal: \(withHeadings.count)/\(idx.documents.count) pages, "
        + "sample: \(withHeadings.first.map { String($0.headings.prefix(60)) } ?? "-")")
    #expect(!withHeadings.isEmpty, "前 500 页应至少一页含 h1~h6 小标题")
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func relevanceRankingOnBenchmark() throws {
    let c = try CHMContainer(path: benchmarkCHMPath)
    let idx = try CHMSearchIndex.build(container: c)
    // 单词查询结果集不变性:与独立子串计数一致(排序可变,集合不变)
    let expected = idx.documents.filter {
        $0.titleLower.contains("法术") || $0.textLower.contains("法术")
    }.count
    let r = idx.searchResults("法术", limit: 200)
    #expect(r.total == expected, "单词查询的命中文档集合不应变化")
    // 多词 AND:命中数不多于单词;零结果不回退 OR
    let multi = idx.searchResults("法术 职业", limit: 10)
    #expect(multi.total <= r.total)
    // 打分观测(人工检视):top-5 标题+分数,整轮打分耗时
    let t = Date()
    let scored = idx.scoredResults("法术")
    let elapsed = Date().timeIntervalSince(t)
    for (i, s) in scored.prefix(5).enumerated() {
        print("RANK \(i + 1) score=\(String(format: "%.2f", s.score)) \(s.hit.title)")
    }
    print("BENCH relevance: 法术 scored \(scored.count) docs in \(String(format: "%.2f", elapsed))s")
}
