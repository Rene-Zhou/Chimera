import Foundation

/// 验收基准文件:DND.26.09.13.chm(36.7MB,zh-CN/GBK,7028 个 HTML 页,
/// 含 .hhc/.hhk/$FIftiMain;UTF-8 内部路径)。
/// 可用环境变量 CHIMERA_BENCHMARK_CHM 覆盖路径
/// (用于在缺少基准文件的机器上验证依赖测试被跳过而非失败)。
let benchmarkCHMPath: String = {
    let env = ProcessInfo.processInfo.environment["CHIMERA_BENCHMARK_CHM"]
    let raw = (env?.isEmpty == false) ? env! : "~/Downloads/DND.26.09.13.chm"
    return NSString(string: raw).expandingTildeInPath
}()

/// 基准文件是否存在:依赖基准文件的测试用 `.enabled(if: benchmarkCHMExists)` 跳过。
let benchmarkCHMExists = FileManager.default.fileExists(atPath: benchmarkCHMPath)
