import Testing
import Foundation
@testable import ChimeraCore

// CHMHTMLEscape.escape —— HTML 文本/属性上下文的最小转义
// (P2-13:404 提示页把请求路径直插 HTML,需先经此转义)

@Test func escapesAllFiveSpecialCharacters() {
    // 五个敏感字符逐一覆盖
    #expect(CHMHTMLEscape.escape("&") == "&amp;")
    #expect(CHMHTMLEscape.escape("<") == "&lt;")
    #expect(CHMHTMLEscape.escape(">") == "&gt;")
    #expect(CHMHTMLEscape.escape("\"") == "&quot;")
    #expect(CHMHTMLEscape.escape("'") == "&#39;")
}

@Test func leavesPlainAndChineseTextUntouched() {
    // 普通路径与中文原样返回
    #expect(CHMHTMLEscape.escape("速查/资源简写.htm") == "速查/资源简写.htm")
    #expect(CHMHTMLEscape.escape("/guide/page-1.htm?q=1") == "/guide/page-1.htm?q=1")
}

@Test func emptyStringStaysEmpty() {
    #expect(CHMHTMLEscape.escape("") == "")
}

@Test func escapesMixedString() {
    // 混合串:五个字符各出现一次
    #expect(CHMHTMLEscape.escape("a<b>&\"'c") == "a&lt;b&gt;&amp;&quot;&#39;c")
}

@Test func escapesAlreadyEscapedEntityAgain() {
    // 已含实体的输入再次转义(不幂等是正确行为):
    // 浏览器会把 "&amp;" 渲染为字面 "&amp;",再转义即 "&amp;amp;"
    #expect(CHMHTMLEscape.escape("a&amp;b") == "a&amp;amp;b")
}

@Test func escapesAttackerCraftedPath() {
    // 404 页攻击样例:路径插 <script> 与属性逃逸均被中和
    #expect(
        CHMHTMLEscape.escape("/x\"><script>alert(1)</script>")
            == "/x&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;"
    )
}
