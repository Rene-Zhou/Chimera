import Testing
import Foundation
@testable import ChimeraCore

// 合成样本锚定解析语义;真实样本(Tests/Fixtures)锚定基准数据。
// 基准 .hhc 结构(实测,DND.26.09.13.chm):根下第1项"写在前面"(写在前面.html),
// 第2项"本书速查"→子项"职业速查"(玩家手册2024/第三章：角色职业.htm)
// →孙项"野蛮人"→曾孙项"狂战士道途"等,共 8514 项。

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

@Test func parsesHHKMultiNamePrefersCleanKeyword() {
    // 新书(DND.26.09.13)真实形态:首个 Name 是 "书\章\词条" 层级别名,
    // 第二个 Name 才是干净词条;索引应显示干净词条
    let hhk = """
    <UL><LI><OBJECT type="text/sitemap">
    <param name="Name" value="荒洲探险家指南\\荒洲宝藏\\分裂遗物">
    <param name="Name" value="诀别遗物">
    <param name="Local" value="荒洲探险家指南/荒洲宝藏/诀别遗物.html">
    </OBJECT></UL>
    """
    let idx = CHMSitemapParser.parseIndex(hhk)
    #expect(idx.count == 1)
    #expect(idx[0].keyword == "诀别遗物", "应避开含 \\ 的层级别名")
    #expect(idx[0].targets == ["荒洲探险家指南/荒洲宝藏/诀别遗物.html"])
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

    #expect(toc.count >= 10, "顶层应有数十个分区")
    #expect(toc[0].title == "写在前面")
    #expect(toc[0].local == "写在前面.html")

    let quickRef = try #require(toc.first { $0.title == "本书速查" }, "应含 本书速查 顶层项")
    #expect(quickRef.local == "速查/资源简写.htm")
    let classes = try #require(quickRef.children.first { $0.title == "职业速查" },
                               "本书速查 子项应含 职业速查")
    #expect(classes.local == "玩家手册2024/第三章：角色职业.htm", "子目录内部路径原样保留")
    let classChildren = classes.children.map(\.title)
    #expect(classChildren.contains("野蛮人"))
    #expect(classChildren.contains("吟游诗人"))
    let barb = try #require(classes.children.first { $0.title == "野蛮人" })
    #expect(barb.children.map(\.title).contains("狂战士道途"), "三级嵌套(道途)应挂在职业下")

    // 深度统计:真实书目录项应有数千个
    func count(_ items: [CHMTocItem]) -> Int { items.reduce(0) { $0 + 1 + count($1.children) } }
    #expect(count(toc) > 1000, "全书目录项应远超 1000,实际 \(count(toc))")
}

@Test func parsesBenchmarkHHK() throws {
    // 基准文件的 .hhk 为真实索引(21 条,双 Name 形态:层级别名 + 干净词条)
    let text = CHMTextDecoder(lcid: 0x0804).decode(try fixture("benchmark.hhk"))
    let idx = CHMSitemapParser.parseIndex(text)
    #expect(idx.count > 10, "基准 .hhk 应有真实索引项,实际 \(idx.count)")
    let relic = try #require(idx.first { $0.keyword == "诀别遗物" },
                             "索引应含干净词条 诀别遗物(而非 书\\章\\词条 层级别名)")
    #expect(relic.targets == ["荒洲探险家指南/荒洲宝藏/诀别遗物.html"])
}
