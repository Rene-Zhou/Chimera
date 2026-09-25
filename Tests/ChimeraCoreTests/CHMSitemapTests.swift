import Testing
import Foundation
@testable import ChimeraCore

// 合成样本锚定解析语义;真实样本(Tests/Fixtures)锚定基准数据。
// 基准 .hhc 结构(实测):根下第1项"——核心规则——"($$unsavedpage1.htm),
// 第2项"玩家手册"→子项"序章:欢迎来到冒险世界"→孙项"你需要什么"等,
// 序章的 UL 关闭后"第一章:进行游戏"回到玩家手册层(兄弟)。

// MARK: - 合成样本

@Test func parsesSyntheticTOCNesting() {
    let html = """
    <HTML><BODY>
    <OBJECT type="text/site properties">
    <param name="Font" value=",10,134">
    </OBJECT>
    <UL>
    <LI><OBJECT type="text/sitemap">
    <param name="Name" value="第一章">
    <param name="Local" value="ch1.htm">
    </OBJECT>
    <UL>
    <LI><OBJECT type="text/sitemap">
    <param name="Name" value="第一节">
    <param name="Local" value="ch1s1.htm">
    </OBJECT>
    <LI><OBJECT type="text/sitemap">
    <param name="Name" value="第二节">
    <param name="Local" value="ch1s2.htm">
    </OBJECT>
    </UL>
    <LI><OBJECT type="text/sitemap">
    <param name="Name" value="第二章">
    <param name="Local" value="ch2.htm">
    </OBJECT>
    </UL>
    </BODY></HTML>
    """
    let toc = CHMSitemapParser.parseTOC(html)
    #expect(toc.count == 2)
    #expect(toc[0].title == "第一章")
    #expect(toc[0].local == "ch1.htm")
    #expect(toc[0].children.count == 2)
    #expect(toc[0].children[1].title == "第二节")
    #expect(toc[1].title == "第二章")
    #expect(toc[1].children.isEmpty)
}

@Test func parsesMergeParamAndMissingLocal() {
    let html = """
    <UL><LI><OBJECT type="text/sitemap">
    <param name="Name" value="附录">
    <param name="Merge" value="appendix.hhc">
    </OBJECT></UL>
    """
    let toc = CHMSitemapParser.parseTOC(html)
    #expect(toc.count == 1)
    #expect(toc[0].merge == "appendix.hhc")
    #expect(toc[0].local == nil)
}

@Test func ignoresSitePropertiesObject() {
    let html = """
    <OBJECT type="text/site properties">
    <param name="FrameName" value="right">
    <param name="Font" value=",13,134">
    </OBJECT>
    <UL><LI><OBJECT type="text/sitemap">
    <param name="Name" value="仅此一项">
    <param name="Local" value="only.htm">
    </OBJECT></UL>
    """
    let toc = CHMSitemapParser.parseTOC(html)
    #expect(toc.map(\.title) == ["仅此一项"], "site properties 对象不得产生目录项")
}

@Test func parsesSyntheticHHKIndex() {
    let hhk = """
    <UL>
    <LI><OBJECT type="text/sitemap">
    <param name="Keyword" value="豁免">
    <param name="Name" value="豁免检定">
    <param name="Local" value="save.htm">
    <param name="Local" value="save2.htm">
    </OBJECT>
    <LI><OBJECT type="text/sitemap">
    <param name="Keyword" value="先攻">
    <param name="Local" value="init.htm">
    </OBJECT>
    </UL>
    """
    let idx = CHMSitemapParser.parseIndex(hhk)
    #expect(idx.count == 2)
    #expect(idx[0].keyword == "豁免", "索引词条应取 Keyword 而非 Name")
    #expect(idx[0].targets == ["save.htm", "save2.htm"])
    #expect(idx[1].keyword == "先攻")
    #expect(idx[1].targets == ["init.htm"])
}

// MARK: - 基准样本

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // ChimeraCoreTests/
        .deletingLastPathComponent()      // Tests/
        .appendingPathComponent("Fixtures/\(name)")
    return try Data(contentsOf: url)
}

@Test func parsesBenchmarkTOC() throws {
    let text = CHMTextDecoder(lcid: 0x0804).decode(try fixture("benchmark.hhc"))
    let toc = CHMSitemapParser.parseTOC(text)

    #expect(toc.count >= 2, "顶层至少含 核心规则/玩家手册")
    #expect(toc[0].title == "——核心规则——")
    #expect(toc[0].local == "$$unsavedpage1.htm")

    let player = try #require(toc.first { $0.title == "玩家手册" }, "应含 玩家手册 顶层项")
    let preface = try #require(player.children.first { $0.title == "序章：欢迎来到冒险世界" },
                               "玩家手册 子项应含序章")
    let grandChildren = preface.children.map(\.title)
    #expect(grandChildren.contains("你需要什么"))
    #expect(grandChildren.contains("使用本书"))
    #expect(grandChildren.contains("充满冒险的世界"))

    let playerChildren = player.children.map(\.title)
    #expect(playerChildren.contains("第一章：进行游戏"),
           "序章 UL 关闭后 第一章 应回到玩家手册层")

    // 深度统计:真实书目录项应有数百个
    func count(_ items: [CHMTocItem]) -> Int { items.reduce(0) { $0 + 1 + count($1.children) } }
    #expect(count(toc) > 100, "全书目录项应远超 100,实际 \(count(toc))")
}

@Test func benchmarkHHKIsEmptyShell() throws {
    // 基准文件的 .hhk 是生成器留下的空壳(仅 site properties + 空 UL)
    let text = CHMTextDecoder(lcid: 0x0804).decode(try fixture("benchmark.hhk"))
    #expect(CHMSitemapParser.parseIndex(text).isEmpty)
}
