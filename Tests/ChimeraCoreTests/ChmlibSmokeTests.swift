import Testing
import Foundation
import CChmlib

/// m1-2 桥接冒烟:证明 vendored chmlib 能在 Swift 侧编译、打开并遍历真实 CHM。
@Test(.enabled(if: benchmarkCHMExists, "基准 CHM 文件缺失(可用 CHIMERA_BENCHMARK_CHM 指定)"))
func chmlibOpensAndEnumeratesBenchmarkFile() throws {
    guard let file = chm_open(benchmarkCHMPath) else {
        Issue.record("chm_open 返回 NULL")
        return
    }
    defer { chm_close(file) }

    // 1) 能解析内嵌全文检索库 /$FIftiMain(文件探查阶段确认存在)
    var info = chmUnitInfo()
    #expect(
        chm_resolve_object(file, "/$FIftiMain", &info) == CHM_RESOLVE_SUCCESS,
        "应能解析 /$FIftiMain"
    )
    #expect(info.length > 0)

    // 2) 枚举普通条目,数量应远超 100(目录探查已见数十个 .htm + 压缩内容)
    var count: Int32 = 0
    let callback: CHM_ENUMERATOR = { _, _, context in
        guard let context else { return 0 }
        let counter = context.assumingMemoryBound(to: Int32.self)
        counter.pointee += 1
        return 1 // CHM_ENUMERATOR_CONTINUE
    }
    #expect(chm_enumerate(file, Int32(CHM_ENUMERATE_NORMAL), callback, &count) != 0)
    #expect(count > 100, "基准文件条目数应远超 100,实际 \(count)")
}
