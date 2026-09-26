import Testing
import Foundation
@testable import ChimeraCore

/// CHMContainer API 契约测试(基准文件快照数据)
private func makeContainer() throws -> CHMContainer {
    try #require(benchmarkCHMExists, "基准文件缺失")
    return try CHMContainer(path: benchmarkCHMPath)
}

@Test func containerRejectsMissingFile() {
    #expect(throws: CHMError.fileNotFound("/no/such/file.chm")) {
        _ = try CHMContainer(path: "/no/such/file.chm")
    }
}

@Test func containerRejectsNonCHMFile() throws {
    let notCHM = NSTemporaryDirectory() + "chimera-not-a-chm.bin"
    try Data([0x00, 0x01, 0x02, 0x03]).write(to: URL(fileURLWithPath: notCHM))
    defer { try? FileManager.default.removeItem(atPath: notCHM) }
    #expect(throws: CHMError.self) {
        _ = try CHMContainer(path: notCHM)
    }
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerEnumeratesBenchmarkEntries() throws {
    let c = try makeContainer()
    let entries = try c.allEntries()
    #expect(entries.count > 100, "基准文件条目数应远超 100,实际 \(entries.count)")

    let paths = Set(entries.map(\.path))
    // 目录探查(CLI list)确认的基准文件真实关键内部文件
    #expect(paths.contains("/$FIftiMain"), "应含内嵌全文检索库")
    #expect(paths.contains("/DND五版不全书.hhc"), "应含目录文件")
    #expect(paths.contains("/DND五版不全书.hhk"), "应含索引文件")
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerResolvesEntryByPath() throws {
    let c = try makeContainer()
    let fifti = c.entry(at: "/$FIftiMain")
    #expect(fifti != nil)
    #expect(fifti?.length ?? 0 > 0)

    // 大小写与首斜杠容错由调用方负责;不存在路径必须干净返回 nil
    #expect(c.entry(at: "/definitely/not/here.htm") == nil)
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerReadsEntryBytes() throws {
    let c = try makeContainer()

    // .hhc 是小文件:整读,长度必须与条目元数据一致
    let hhcPath = "/DND五版不全书.hhc"
    let hhc = try c.read(hhcPath)
    let meta = c.entry(at: hhcPath)
    #expect(hhc.count > 0)
    #expect(UInt64(hhc.count) == meta?.length)

    // $FIftiMain 很大:按区间读前 64 字节
    let head = try c.read("/$FIftiMain", range: 0..<64)
    #expect(head.count == 64)

    // 尾部区间读:末 16 字节
    guard let len = c.entry(at: "/$FIftiMain")?.length else {
        Issue.record("缺少 /$FIftiMain 元数据"); return
    }
    let tail = try c.read("/$FIftiMain", range: (len - 16)..<len)
    #expect(tail.count == 16)
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerThrowsOnMissingEntryRead() throws {
    let c = try CHMContainer(path: benchmarkCHMPath)
    #expect(throws: CHMError.entryNotFound("/ghost.htm")) {
        _ = try c.read("/ghost.htm")
    }
}

// MARK: - 零 resolve 读取契约(read(entry:)/start/space)

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerEntryCarriesLocationFields() throws {
    let c = try makeContainer()
    let entries = try c.allEntries()
    // 枚举产出的条目应携带定位信息(空间合法 + 与按路径解析一致)
    let html = try #require(entries.first { !$0.isDirectory && $0.path.hasSuffix(".hhc") })
    #expect(html.space == 0 || html.space == 1, "space 应为 CHM_UNCOMPRESSED/CHM_COMPRESSED")
    let resolved = try #require(c.entry(at: html.path), "按路径解析同一页应成功")
    #expect(resolved == html, "枚举与解析产出的条目(含 start/space)应一致")
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerReadByEntryMatchesReadByPath() throws {
    let c = try makeContainer()
    let entries = try c.allEntries()
    // 整读等价:.hhc 小文件
    let hhc = try #require(entries.first { $0.path.hasSuffix(".hhc") })
    let viaEntry = try c.read(entry: hhc)
    let viaPath = try c.read(hhc.path)
    #expect(viaEntry == viaPath, "零 resolve 读取应与路径读取字节一致")
    // 区间读等价:$FIftiMain 头 4KB(大压缩条目)
    let fifti = try #require(entries.first { $0.path == "/$FIftiMain" })
    let headEntry = try c.read(entry: fifti, range: 0..<4096)
    let headPath = try c.read("/$FIftiMain", range: 0..<4096)
    #expect(headEntry == headPath)
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerSetCacheBlockCountKeepsReadsCorrect() throws {
    let c = try makeContainer()
    c.setCacheBlockCount(128)
    let entries = try c.allEntries()
    let hhc = try #require(entries.first { $0.path.hasSuffix(".hhc") })
    // 调大缓存后读取仍应正确,且与默认缓存时字节一致
    let after = try c.read(entry: hhc)
    c.setCacheBlockCount(5)
    let restored = try c.read(entry: hhc)
    #expect(after == restored)
    // 非法容量应被忽略而非崩溃
    c.setCacheBlockCount(0)
    _ = try c.read(entry: hhc)
}
