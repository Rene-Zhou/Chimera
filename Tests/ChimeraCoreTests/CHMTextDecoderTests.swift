import Testing
import Foundation
@testable import ChimeraCore

// 样本字节由 python3 实算(勿凭记忆):
// "法术".encode("gbk")    = b7 a8 ca f5
// "法術".encode("big5")   = aa 6b b3 4e
// "法术".encode("utf-8")  = e6 b3 95 e6 9c af

@Test func lcidToCharsetName() {
    #expect(CHMCharset.name(forLCID: 0x0804) == "GBK")          // zh-CN
    #expect(CHMCharset.name(forLCID: 0x1004) == "GBK")          // zh-SG
    #expect(CHMCharset.name(forLCID: 0x0404) == "Big5")         // zh-TW
    #expect(CHMCharset.name(forLCID: 0x0411) == "Shift_JIS")    // ja-JP
    #expect(CHMCharset.name(forLCID: 0x0412) == "EUC-KR")       // ko-KR
    #expect(CHMCharset.name(forLCID: 0x0409) == "windows-1252") // en-US
    #expect(CHMCharset.name(forLCID: 0x9999) == nil)
}

@Test func decodesGBKViaLCID() {
    let gbk = Data([0xB7, 0xA8, 0xCA, 0xF5]) // 法术
    let d = CHMTextDecoder(lcid: 0x0804, declaredCharset: nil)
    #expect(d.decode(gbk) == "法术")
}

@Test func decodesBig5ViaLCID() {
    let big5 = Data([0xAA, 0x6B, 0xB3, 0x4E]) // 法術
    let d = CHMTextDecoder(lcid: 0x0404, declaredCharset: nil)
    #expect(d.decode(big5) == "法術")
}

@Test func decodesUTF8ViaDeclaredCharset() {
    let utf8 = Data([0xE6, 0xB3, 0x95, 0xE6, 0x9C, 0xAF]) // 法术
    let d = CHMTextDecoder(lcid: 0x0409, declaredCharset: "utf-8")
    #expect(d.decode(utf8) == "法术")
}

@Test func stripsUTF8BOMAndDecodes() {
    let bom = Data([0xEF, 0xBB, 0xBF]) + Data("法术".utf8)
    let d = CHMTextDecoder(lcid: nil, declaredCharset: nil)
    #expect(d.decode(bom) == "法术", "BOM 应被剥离且按 UTF-8 解码")
}

@Test func declaredCharsetWrongFallsBackToLCID() {
    // 声明 utf-8 但实际字节是 GBK → 应回退到 LCID 的 GBK
    let gbk = Data([0xB7, 0xA8, 0xCA, 0xF5])
    let d = CHMTextDecoder(lcid: 0x0804, declaredCharset: "utf-8")
    #expect(d.decode(gbk) == "法术")
}

@Test func sniffsGBKWithoutAnyHint() {
    // 无声明、无 LCID:GBK 字节不是合法 UTF-8,应嗅探回退到 GBK(zh CHM 惯例)
    let gbk = Data([0xB7, 0xA8, 0xCA, 0xF5])
    let d = CHMTextDecoder(lcid: nil, declaredCharset: nil)
    #expect(d.decode(gbk) == "法术")
}

@Test func pureASCIIAlwaysDecodes() {
    let ascii = Data("<!DOCTYPE HTML PUBLIC>".utf8)
    #expect(CHMTextDecoder(lcid: 0x0804, declaredCharset: nil).decode(ascii)
            == "<!DOCTYPE HTML PUBLIC>")
}

// MARK: - meta charset 嗅探(CHMCharset.declared(in:))

@Test func sniffsDeclaredCharsetQuotedVariants() {
    // 双引号
    #expect(CHMCharset.declared(in: Data(#"<meta charset="utf-8">"#.utf8)) == "utf-8")
    // 单引号
    #expect(CHMCharset.declared(in: Data("<meta charset='GBK'>".utf8)) == "GBK")
    // 无引号(以 > 结尾)
    #expect(CHMCharset.declared(in: Data("<meta charset=Big5>".utf8)) == "Big5")
    // 无引号(以空白结尾)
    #expect(CHMCharset.declared(in: Data("<meta charset=gbk >".utf8)) == "gbk")
    // 分号结尾(http-equiv 形态)
    #expect(CHMCharset.declared(in:
        Data(#"<meta http-equiv="Content-Type" content="text/html; charset=windows-1251">"#.utf8))
        == "windows-1251")
}

@Test func sniffsDeclaredCharsetCaseInsensitive() {
    #expect(CHMCharset.declared(in: Data(#"<META CHARSET="Shift_JIS">"#.utf8)) == "Shift_JIS")
    #expect(CHMCharset.declared(in: Data("<meta CharSet=euc-jp>".utf8)) == "euc-jp")
}

@Test func declaredCharsetNilWhenAbsent() {
    #expect(CHMCharset.declared(in: Data("<html><body>无声明</body></html>".utf8)) == nil)
    #expect(CHMCharset.declared(in: Data()) == nil)
    // 引号未闭合 → nil
    #expect(CHMCharset.declared(in: Data(#"<meta charset="utf-8"#.utf8)) == nil)
}

@Test func declaredCharsetBeyond4KBNotFound() {
    // 声明出现在前 4KB 之外 → 找不到(与渲染管线一致,只嗅探头部)
    let pad = String(repeating: " ", count: 5000)
    #expect(CHMCharset.declared(in: Data((pad + "<meta charset=utf-8>").utf8)) == nil)
}

// MARK: - 按页解码(搜索索引构建与渲染管线共用)

@Test func decodePerPageHonoursDeclaredCharsetOverLCID() {
    // zh-CN LCID(默认 GBK),但页面声明 Big5:应按 Big5 解码
    let html = Data("<meta charset=Big5>".utf8) + Data([0xAA, 0x6B, 0xB3, 0x4E]) // 法術
    #expect(CHMTextDecoder.decode(html, lcid: 0x0804).contains("法術"))
}

@Test func decodePerPageFallsBackToLCIDWithoutDeclaration() {
    // 无声明:回退到 LCID(zh-CN → GBK)
    let gbk = Data([0xB7, 0xA8, 0xCA, 0xF5]) // 法术
    #expect(CHMTextDecoder.decode(gbk, lcid: 0x0804) == "法术")
}
