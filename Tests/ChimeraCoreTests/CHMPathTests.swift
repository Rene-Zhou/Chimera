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
