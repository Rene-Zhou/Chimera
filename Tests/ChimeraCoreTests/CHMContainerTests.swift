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

// MARK: - 读取路径单次 resolve 与条目查询缓存(P0-3)
// resolveCount 为测试观测口:仅统计真实 chm_resolve_object 调用,
// 缓存命中/复用不计入。

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerRepeatedQueriesHitEntryCache() throws {
    let c = try makeContainer()
    _ = try c.allEntries()
    // allEntries 内部 systemInfo() 会对 "/#SYSTEM" 做一次 resolve(lcid 探测所需,
    // 先于枚举填充缓存),这是合法基线;后续重复精确查询不应再增加 resolve
    let base = c.resolveCount
    #expect(base <= 1, "枚举 + lcid 探测最多一次 resolve,实际 \(base) 次")

    // 同一路径重复精确查询:应全部命中缓存,零 resolve
    for _ in 0..<10 { _ = c.entry(at: "/$FIftiMain") }
    #expect(c.resolveCount == base, "重复精确查询应命中枚举填充的缓存,实际多出 \(c.resolveCount - base) 次 resolve")

    // 命中缓存的查询仍须返回正确条目(与首次解析一致)
    let entry = try #require(c.entry(at: "/$FIftiMain"))
    #expect(entry.length > 0)
    #expect(entry.space == 0 || entry.space == 1)

    // 不存在的路径仍干净返回 nil,且不污染缓存
    #expect(c.entry(at: "/definitely/not/here.htm") == nil)
    #expect(c.entry(at: "/$FIftiMain") != nil)
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerReadByPathResolvesOnce() throws {
    let c = try makeContainer()
    let before = c.resolveCount
    let hhc = try c.read("/DND五版不全书.hhc")
    #expect(hhc.count > 0)
    #expect(c.resolveCount - before == 1, "read(_:) 应单次 resolve,实际 \(c.resolveCount - before) 次")

    // 再读一次:应命中条目缓存,零额外 resolve
    _ = try c.read("/DND五版不全书.hhc")
    #expect(c.resolveCount - before == 1, "重复 read(_:) 应命中缓存,实际 \(c.resolveCount - before) 次")

    // 区间读同样受益
    _ = try c.read("/$FIftiMain", range: 0..<64)
    #expect(c.resolveCount - before == 2, "区间读新路径应仅一次 resolve,实际 \(c.resolveCount - before - 1) 次额外")
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerCaseVariantPathResolvesViaFallback() throws {
    let c = try makeContainer()
    _ = try c.allEntries()
    let base = c.resolveCount
    let exact = try #require(c.entry(at: "/$FIftiMain"))
    #expect(c.resolveCount == base, "精确匹配应命中缓存")

    // 大小写变体:精确匹配 miss,走 chmlib 不敏感匹配 resolve 兑底
    // (实测 chmlib 对 "/$FiFtImAiN" 可解析;对 "/$fiiftimain" 会因分支
    //  路由按大小写敏感排序而误路由失败——两种结果都必须保持不变)
    let variant = try #require(c.entry(at: "/$FiFtImAiN"), "可解析变体应经 chmlib 不敏感匹配解析")
    #expect(c.resolveCount == base + 1, "变体首次解析应走一次 resolve 兑底")
    #expect(variant.length == exact.length, "变体解析应指向同一实体")
    #expect(variant.path == "/$FiFtImAiN", "返回条目保持请求路径(原语义)")

    // 变体同样回填缓存:再次查询零 resolve
    _ = c.entry(at: "/$FiFtImAiN")
    #expect(c.resolveCount == base + 1, "变体回填缓存后不应重复 resolve")

    // 变体读取与精确路径读取字节一致
    let viaVariant = try c.read("/$FiFtImAiN", range: 0..<128)
    let viaExact = try c.read("/$FIftiMain", range: 0..<128)
    #expect(viaVariant == viaExact)

    // chmlib 层面解析失败的变体:缓存后仍须返回 nil
    // (缓存用精确键,不得“顺手”把不敏感匹配变成能力增强)
    #expect(c.entry(at: "/$fiiftimain") == nil, "chmlib 路由失败的变体应保持 nil")
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerRepeatedReadsMatchFirstResult() throws {
    let c = try makeContainer()
    let path = "/DND五版不全书.hhc"
    let firstRead = try c.read(path)
    let firstEntry = try #require(c.entry(at: path))

    // 同一路径连续 read(_:)/entry(at:):缓存命中路径结果与首次完全一致
    for _ in 0..<3 {
        #expect(try c.read(path) == firstRead)
        #expect(c.entry(at: path) == firstEntry)
    }

    // 大条目区间读同样稳定
    let head = try c.read("/$FIftiMain", range: 0..<64)
    for _ in 0..<3 {
        #expect(try c.read("/$FIftiMain", range: 0..<64) == head)
    }

    // 缺前导斜杠的路径自动补全(归一化后同键,也应命中缓存)
    let noSlash = try #require(c.entry(at: "$FIftiMain"))
    #expect(noSlash.path == "/$FIftiMain")
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerReadPathVsEntryBytesConsistentAfterCacheWarm() throws {
    let c = try makeContainer()
    let entries = try c.allEntries()
    // 缓存已暖后 read(_:)(单次 resolve/缓存命中)与零 resolve 的 read(entry:) 字节一致
    let sample = entries.filter {
        !$0.isDirectory
            && ($0.path.hasSuffix(".hhc") || $0.path.hasSuffix(".hhk")
                || $0.path.hasSuffix(".htm") || $0.path.hasSuffix(".html"))
    }.prefix(8)
    #expect(sample.count > 0, "基准文件应含可采样页面")
    for e in sample {
        let viaPath = try c.read(e.path)
        let viaEntry = try c.read(entry: e)
        #expect(viaPath == viaEntry, "路径读取与零 resolve 读取应字节一致:\(e.path)")
    }

    // 大压缩条目区间读也一致
    let fifti = try #require(entries.first { $0.path == "/$FIftiMain" })
    let headPath = try c.read("/$FIftiMain", range: 0..<4096)
    let headEntry = try c.read(entry: fifti, range: 0..<4096)
    #expect(headPath == headEntry)
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerSystemInfoUsesEntryCache() throws {
    let c = try makeContainer()
    // 先预热 /#SYSTEM 条目缓存(经 resolve 回填)
    _ = c.entry(at: "/#SYSTEM")
    let base = c.resolveCount
    let warmed = try c.systemInfo()
    #expect(c.resolveCount == base, "systemInfo 首次解析应命中条目缓存,实际多出 \(c.resolveCount - base) 次 resolve")

    // 与冷缓存容器结果一致(正确性不受缓存影响)
    let c2 = try makeContainer()
    let cold = try c2.systemInfo()
    #expect(warmed == cold, "缓存命中路径的 systemInfo 应与冷路径结果一致")
    #expect(warmed != nil, "基准文件应含 /#SYSTEM")

    // 重复调用 systemInfo() 结果稳定(自身缓存 + 条目缓存量重)
    #expect(try c.systemInfo() == warmed)
}

@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func containerReadRangeOutOfBoundsStillThrowsReadFailed() throws {
    let c = try makeContainer()
    _ = try c.allEntries()
    let length = try #require(c.entry(at: "/$FIftiMain")).length
    // 错误语义保持:range 越界抛 readFailed(即使条目已命中缓存)
    do {
        _ = try c.read("/$FIftiMain", range: 0..<(length + 1))
        Issue.record("越界区间应抛 readFailed")
    } catch let e as CHMError {
        guard case .readFailed = e else {
            Issue.record("应为 readFailed,实际 \(e)"); return
        }
        #expect(Bool(true))
    }
    // 条目不存在语义保持:entryNotFound
    do {
        _ = try c.read("/ghost.htm")
        Issue.record("缺失条目应抛 entryNotFound")
    } catch let e as CHMError {
        guard case .entryNotFound = e else {
            Issue.record("应为 entryNotFound,实际 \(e)"); return
        }
        #expect(Bool(true))
    }
}
