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
