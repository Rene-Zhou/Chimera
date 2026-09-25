import Testing
import Foundation
@testable import ChimeraCore

// #SYSTEM 实测格式(基准文件 hexdump 破译):
// DWORD version + { WORD code, WORD len, data[len] }*N
// code 2=默认页(容器编码) code 3=标题 code 4=LCID(DWORD)

private func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func u32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}
private func entry(_ code: UInt16, _ data: [UInt8]) -> [UInt8] {
    u16(code) + u16(UInt16(data.count)) + data
}

@Test func parsesSyntheticSystemInfo() {
    var d = u32(3)
    d += entry(4, u32(0x0804))
    d += entry(2, Array("玩家手册2024.htm".utf8))
    d += entry(3, Array("测试书".utf8))
    let info = CHMSystemInfoParser.parse(Data(d))
    #expect(info?.lcid == 0x0804)
    #expect(info?.defaultTopic == "玩家手册2024.htm")
    #expect(info?.title == "测试书")
}

@Test func systemInfoNilOnGarbage() {
    #expect(CHMSystemInfoParser.parse(Data([0x01])) == nil)
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func parsesBenchmarkSystemInfo() throws {
    let c = try CHMContainer(path: benchmarkCHMPath)
    let info = try #require(try c.systemInfo(), "基准文件应含 /#SYSTEM")
    #expect(info.lcid == 0x0804)
    #expect(info.defaultTopic == "写在前面.html")
    #expect(info.title == "五版不全书")
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func decodesChineseEntryPaths() throws {
    let c = try CHMContainer(path: benchmarkCHMPath)
    let paths = try c.allEntries().map(\.path)
    #expect(paths.contains("/写在前面.html"), "中文内部路径应正确解码(本文件为 UTF-8 路径)")
    #expect(paths.contains("/玩家手册2024/第三章：角色职业.htm"), "子目录中文路径应正确解码")
}

@Test func decodePathFallsBackToLCIDEncoding() {
    // UTF-8 直通
    let utf8 = Array("玩家手册2024.htm".utf8)
    #expect(CHMContainer.decodePath(utf8, lcid: 0x0804) == "玩家手册2024.htm")
    // GBK 路径字节(典型 Windows 生成文件)→ LCID 回退(实测:玩家手册 的 GBK 编码)
    let gbk: [UInt8] = [0xCD, 0xE6, 0xBC, 0xD2, 0xCA, 0xD6, 0xB2, 0xE1]
    #expect(CHMContainer.decodePath(gbk, lcid: 0x0804) == "玩家手册")
}
