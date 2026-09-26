# 性能与实现问题审查(2026-09-27)

> **状态:已修复完毕(同日整合)**。P0 全部、P1-7/8/9、P2-10/11/12/13 已落地;
> 验收:71/71 测试全绿(基线 53),全量冒烟 7 场景 PASS,索引构建
> 7028 页 16.31s → 4.19s(≈3.9×)。P1-6、P2-14、P2-15 明确暂缓(见文末)。
> 来源:全量代码审查。按影响分级编号;每条标注负责工作流(WS-A~D)、
> 涉及文件与验收标准。文件所有权互斥,确保 4 个并行 worktree 无合并冲突。
> 测试规范:swift-testing(`@Test`/`#expect`/`#require`),CLT 环境用
> `./scripts/test.sh` 跑全量;依赖基准书的测试用 `.enabled(if: benchmarkCHMExists)` 门控;
> GUI 层改动用 `./scripts/smoke.sh`(7 场景)验收。

## P0 架构级(高影响)

### P0-1 scheme handler 在主线程做同步 I/O + LZX 解压 【WS-C ✅】
- 文件:`Sources/ChimeraGUI/CHMSchemeHandler.swift`
- 问题:`WKURLSchemeHandler` 回调在主线程调用,`start` 同步执行
  `entry(at:)` + `read()`(pread + LZX 解压),每个子资源(HTML/CSS/图片)
  阻塞主线程直到解压完成。
- 修复:工作派发到后台串行队列;记录活跃 task,`stop` 时标记取消;
  回调(`didReceive`/`didFinish`/`didFailWithError`)回主线程。
  大条目用 `read(path, range:)` 分块流式 `didReceive`(P0-1b,64KB 块)。
- 验收:smoke OPEN/NAV/SEARCH 场景通过;`stop` 被调用后不再向已停止的
  task 发任何回调(WebKit 会因此 crash,需防)。

### P0-2 UI 渲染与后台索引构建争抢同一把锁 【WS-D ✅】
- 文件:`Sources/ChimeraGUI/AppModel.swift`
- 问题:索引构建持 `CHMContainer.NSLock` 逐页解压,WebView 资源请求
  在主线程排队等锁,首开大书边建索引边翻页持续卡顿。
- 修复:`buildIndexIfNeeded` 为构建单独 `CHMContainer(path:)` 打开独立句柄
  (CHM 只读,多句柄安全),UI 句柄不再被索引阻塞。
- 验收:smoke SEARCH 场景通过(该场景同时建索引+导航,天然覆盖)。

### P0-3 一次读取最多 4 次 `chm_resolve_object`,目录页无缓存 【WS-A ✅】
- 文件:`Sources/ChimeraCore/CHMContainer.swift`
- 问题:`read(_:)` = entry(at:) 1 次 + read(range:) 内 2 次;scheme handler
  外面再 1 次。chmlib 每次 resolve 都 malloc + pread 目录页 + 线性扫描,
  无任何缓存(源码自注 XXX)。索引构建 N 页 = 3N 次全量目录树遍历。
- 修复:
  - `read(_ path:)` 走单次 resolve:复用预置的 `read(entry:)`;
  - `entry(at:)` 增加查询缓存:`allEntries()` 顺手填充
    `[path: CHMEntry]` 字典(容器不可变,无需失效);resolve 仅兜底。
- 验收:现有 CHMContainerTests 全绿;新增测试:同一路径连续
  `entry(at:)`/`read(_:)` 结果与首次一致;`read(_:)` 与 `read(entry:)`
  字节一致(基准书)。

### P0-4 索引构建:目录序随机访问 + LZX 重置区间惩罚 + 块缓存仅 5 块 【WS-B ✅】
- 文件:`Sources/ChimeraCore/CHMSearchIndex.swift`
- 问题:build 按目录序(≈路径字典序)读取,与数据物理顺序无关;LZX 有状态,
  随机访问需解压自上次 reset 以来的全部块;`CHM_MAX_BLOCKS_CACHED=5`
  (32KB 块仅 160KB),全代码从未调 `chm_set_param` 调大。
- 修复(在预置的 `build(container:entries:...)` 内部):
  - 条目按 `start`(数据偏移)排序后读取,访问模式变顺序;
  - 构建前 `container.setCacheBlockCount(128)`;
  - 逐页用 `read(entry:)`(零 resolve)。
- 验收:`build(container:entries:)` 与旧行为等价(文档集合一致,基准书);
  新增基准测试对比排序前后 build 耗时(打印即可,不作硬断言)。

### P0-5 `AppModel.open` 全程主线程同步 【WS-D ✅】
- 文件:`Sources/ChimeraGUI/AppModel.swift`
- 问题:`allEntries()`(全目录枚举+路径解码)、.hhc/.hhk 读取+解码+解析
  (大书 TOC 可达 MB 级)全在主线程,大书首开转圈。
- 修复:打开后先以同步最小集(默认页)建标签立即显示,目录/索引解析
  后台完成后回填 UI。**CHIMERA_SMOKE=1 路径必须保持全同步**
  (冒烟状态机依赖同步行为,见 AppModel.tabDidFinish)。
- 验收:smoke 全部 7 场景通过(OPEN/NAV/SEARCH/FIND/HISTORY/TABS/RESTORE)。

## P1 中影响

### P1-6 搜索索引内存/磁盘偏重(暂缓,记录不动)
- `CHMSearchDocument` 持 text+textLower+title+titleLower ≈ 正文 2.5 倍内存;
  plist 缓存全量落盘。当前规模(36MB 书)可接受,改进需侵入摘要生成链,
  本轮不做,留待数据结构升级(倒排/三元组)时一并处理。

### P1-7 `CHMSnippet.around` 每命中复制整页文本 【WS-B ✅】
- 文件:`Sources/ChimeraCore/CHMSearchIndex.swift`
- 问题:`Array(text)` O(页长)/次,200 命中 = 200 次全页拷贝。
- 修复:用 `text.index(_:offsetBy:)` 直接定位窗口边界,不整页拷贝;
  `while s.contains("  ")` 折叠改为单趟扫描。
- 验收:现有 snippet 测试全绿;新增长文本(>100k 字符)正确性测试。

### P1-8 SwiftUI 粗粒度观察:搜索框逐键失效整个侧栏 【WS-D ✅】
- 文件:`Sources/ChimeraGUI/Views/SidebarView.swift`
- 问题:`searchQuery` 每字符变化重算 `TOCFlattener.flatten`(展开态上万节点)
  + LazyVStack 全量 diff;索引过滤同理逐键全量过滤。
- 修复:搜索/索引过滤框输入状态本地化(@State),仅 submit 时写回 model;
  TOC 扁平化按 expanded 集合 memoize(struct 缓存)。
- 验收:smoke 通过;行为不变(回车才搜索;过滤仍即时)。

### P1-9 `plainText` script/style 剥离 O(n·k) + 多趟处理 【WS-B ✅】
- 文件:`Sources/ChimeraCore/CHMSearchIndex.swift`
- 问题:`while range(of:)+removeSubrange` 每块整体拷贝后文;之后三趟拷贝。
- 修复:单趟扫描(标签/注释→script-style 区间跳过、实体解码、空白折叠
  可合并为至多两趟),消除平方行为。
- 验收:现有 extractor 测试全绿;新增多 script 块页面测试。

## P2 小问题 / 健壮性

### P2-10 `highlightJS` 循环内重复 `q.toLowerCase()` 【WS-D ✅】
- 文件:`Sources/ChimeraGUI/ReaderTab.swift`(findJS 已提升,两处不一致)。
- 验收:smoke FIND 场景通过。

### P2-11 首开离线拦截规则异步安装竞态 【WS-D ✅】
- 文件:`Sources/ChimeraGUI/ReaderTab.swift`
- 问题:规则未编译完成时首个页面已加载,外部 http(s) 子资源可能漏网,
  违反 PRD"无外部网络请求"。
- 修复:首个 `load(path:)` 延迟到规则就绪(或编译失败)后再执行;
  后续加载不受阻。
- 验收:代码审查 + smoke;无法单测,逻辑保持简单。

### P2-12 build 静默吞错(`try?`) 【WS-B ✅】
- 修复:读取失败页记录(print 单行汇总即可),不再无声跳过。
- 验收:测试可注入读取失败(不可行则代码审查)。

### P2-13 404 页路径未转义直插 HTML 【WS-C ✅】
- 修复:新增 `CHMCore` 的 `escapeHTML` 小助手(新文件),404 页经转义;
  助手有单测。验收:单测覆盖 `<`、`&`、`"`、中文原样。

### P2-14 每次导航全量写 ReadingState(暂缓)
- 文件小、频度低,可后续 debounce;本轮不动,避免 WS-D 范围膨胀。

### P2-15 缓存孤儿无清理(暂缓,记录不动)
- 移动/替换书文件后 `Caches/Chimera`、Bookmarks、TOCExpansion 产生孤儿;
  需要清理策略设计,单独立项。

## 工作流与文件所有权

| WS  | 文件(独占)                                                                 | 问题                        |
|-----|-------------------------------------------------------------------------------|-----------------------------|
| A   | `Sources/ChimeraCore/CHMContainer.swift`、`Tests/ChimeraCoreTests/CHMContainerTests.swift` | P0-3                        |
| B  | `Sources/ChimeraCore/CHMSearchIndex.swift`、`Tests/ChimeraCoreTests/CHMSearchIndexTests.swift` | P0-4、P1-7、P1-9、P2-12 |
| C  | `Sources/ChimeraGUI/CHMSchemeHandler.swift`、`Sources/ChimeraCore/CHMHTMLEscape.swift`(新)、对应测试 | P0-1、P2-13 |
| D  | `Sources/ChimeraGUI/AppModel.swift`、`Sources/ChimeraGUI/ReaderTab.swift`、`Sources/ChimeraGUI/Views/SidebarView.swift` | P0-2、P0-5、P1-8、P2-10、P2-11 |

## 预置契约(先行合入 main,各 WS 基于其构建)

1. `CHMEntry` 新增 `space: UInt32`(CHM_UNCOMPRESSED=0/COMPRESSED=1)
   与 `start: UInt64`(数据区偏移),由枚举/解析填充;
2. `CHMContainer.read(entry: CHMEntry) throws -> Data`:零 resolve 读取
   (重建 chmUnitInfo 后直接 `chm_retrieve_object`);
3. `CHMContainer.setCacheBlockCount(_ n: Int)`:封装
   `chm_set_param(CHM_PARAM_MAX_BLOCKS_CACHED)`;
4. `CHMSearchIndex.build(container:entries:tocTitles:progress:)`:
   接收 `allEntries()` 结果(内部自行过滤 .htm/.html),旧签名保持兼容转调。

## 明确不做(本轮)

- P1-6 索引内存结构重构、P2-14 写盘 debounce、P2-15 缓存清理;
- chmlib 内部改动(二分查找目录页等)——vendored 库保持最小侵入。
