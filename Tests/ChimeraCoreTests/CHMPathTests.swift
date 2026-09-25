import Testing
import Foundation
@testable import ChimeraCore

// chm:// scheme 供资源的两个纯逻辑件:
// CHMPath.resolve —— CHM 内部路径语义的相对链接解析(无磁盘、纯字符串)
// CHMMimeType.forPath —— 扩展名 → MIME

@Test func resolvesRelativeLinks() {
    // 基准:base 为文件路径
    #expect(CHMPath.resolve("y.htm", base: "/x/a.htm") == "/x/y.htm")
    #expect(CHMPath.resolve("./y.htm", base: "/x/a.htm") == "/x/y.htm")
    #expect(CHMPath.resolve("sub/y.htm", base: "/x/a.htm") == "/x/sub/y.htm")
    #expect(CHMPath.resolve("../y.htm", base: "/x/a.htm") == "/y.htm")
    #expect(CHMPath.resolve("../../y.htm", base: "/x/a.htm") == "/y.htm", "越顶钳制到根")
    // 绝对路径
    #expect(CHMPath.resolve("/y.htm", base: "/x/a.htm") == "/y.htm")
    // 纯锚点/空 → 原地
    #expect(CHMPath.resolve("#frag", base: "/x/a.htm") == "/x/a.htm")
    #expect(CHMPath.resolve("", base: "/x/a.htm") == "/x/a.htm")
    // 查询串剥离
    #expect(CHMPath.resolve("y.htm?k=v", base: "/x/a.htm") == "/x/y.htm")
    // base 为目录(带尾斜杠)与根
    #expect(CHMPath.resolve("y.htm", base: "/x/") == "/x/y.htm")
    #expect(CHMPath.resolve("y.htm", base: "/") == "/y.htm")
    // 深层穿越组合
    #expect(CHMPath.resolve("../img/a.png", base: "/ch/guide/page.htm") == "/ch/img/a.png")
}

@Test func mapsMIMETypes() {
    #expect(CHMMimeType.forPath("/a/b.htm") == "text/html")
    #expect(CHMMimeType.forPath("/a/b.html") == "text/html")
    #expect(CHMMimeType.forPath("/a/b.HTML") == "text/html", "扩展名大小写不敏感")
    #expect(CHMMimeType.forPath("/s.css") == "text/css")
    #expect(CHMMimeType.forPath("/s.js") == "text/javascript")
    #expect(CHMMimeType.forPath("/p.png") == "image/png")
    #expect(CHMMimeType.forPath("/p.jpg") == "image/jpeg")
    #expect(CHMMimeType.forPath("/p.jpeg") == "image/jpeg")
    #expect(CHMMimeType.forPath("/p.gif") == "image/gif")
    #expect(CHMMimeType.forPath("/p.svg") == "image/svg+xml")
    #expect(CHMMimeType.forPath("/p.bmp") == "image/bmp")
    #expect(CHMMimeType.forPath("/p.ico") == "image/x-icon")
    #expect(CHMMimeType.forPath("/p.bin") == "application/octet-stream")
}

// MARK: - 外链回投(chm-link-back)

// 抓取站生成的 CHM 会把站内交叉引用写成源站绝对 https URL。
// mapExternalToInternal 按"末段文件名(百分号解码后)"回投到容器内页面。

private let linkIndex: [String: String] = [
    "动作.htm": "/动作.htm",
    "术语释义.htm": "/术语释义.htm",
    "gold-dragon.jpg": "/images/gold-dragon.jpg",
]

@Test func mapsExternalLinkToInternalPage() {
    // 基准文件真实形态:百分号编码中文文件名 + 锚点
    let r = CHMPath.mapExternalToInternal(
        "https://5echm.kagangtuya.top/topics/%E7%8E%A9%E5%AE%B6%E6%89%8B%E5%86%8C2024/%E6%9C%AF%E8%AF%AD%E6%B1%87%E7%BC%96/%E5%8A%A8%E4%BD%9C.htm#Attack",
        filenameIndex: linkIndex)
    #expect(r?.path == "/动作.htm")
    #expect(r?.fragment == "Attack")
}

@Test func mapsExternalLinkEdgeCases() {
    // 无锚点
    #expect(CHMPath.mapExternalToInternal(
        "https://example.com/a/术语释义.htm",
        filenameIndex: linkIndex)?.fragment == nil)
    // 文件名大小写不敏感
    #expect(CHMPath.mapExternalToInternal(
        "https://example.com/x/GOLD-Dragon.JPG",
        filenameIndex: linkIndex)?.path == "/images/gold-dragon.jpg")
    // 非 http(s) 不处理
    #expect(CHMPath.mapExternalToInternal("chm://doc/动作.htm", filenameIndex: linkIndex) == nil)
    #expect(CHMPath.mapExternalToInternal("ftp://example.com/动作.htm", filenameIndex: linkIndex) == nil)
    // 容器内没有同名条目 → nil(交给外链兜底)
    #expect(CHMPath.mapExternalToInternal(
        "https://example.com/不存在的页面.htm", filenameIndex: linkIndex) == nil)
    // 无路径末段 → nil
    #expect(CHMPath.mapExternalToInternal("https://example.com/", filenameIndex: linkIndex) == nil)
    // 非法 URL → nil
    #expect(CHMPath.mapExternalToInternal("ht tp://broken", filenameIndex: linkIndex) == nil)
}
