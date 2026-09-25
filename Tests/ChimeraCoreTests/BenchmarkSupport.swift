import Foundation

/// 验收基准文件:5R不全书(7.8MB,zh-CN/GBK,含 .hhc/.hhk/$FIftiMain)。
/// 可用环境变量 CHIMERA_BENCHMARK_CHM 覆盖路径
/// (用于在缺少基准文件的机器上验证依赖测试被跳过而非失败)。
let benchmarkCHMPath: String = {
    let env = ProcessInfo.processInfo.environment["CHIMERA_BENCHMARK_CHM"]
    let raw = (env?.isEmpty == false) ? env! : "~/Downloads/5R不全书（全扩展）2026.9.13.chm"
    return NSString(string: raw).expandingTildeInPath
}()

/// 基准文件是否存在:依赖基准文件的测试用 `.enabled(if: benchmarkCHMExists)` 跳过。
let benchmarkCHMExists = FileManager.default.fileExists(atPath: benchmarkCHMPath)
