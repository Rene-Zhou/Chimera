# Chimera v1.0 验收走查(F1–F12)

基准文件:`~/Downloads/DND.26.09.13.chm`(36.7MB,zh-CN/GBK,7028 个 HTML 页,含 .hhc/.hhk/$FIftiMain,UTF-8 内部路径)
测试:`./scripts/test.sh` **49/49 绿** · `./scripts/smoke.sh` 7/7(隔离状态目录,可重复运行) · 走查日期:2026-09-26(第三轮,基准书更换后)

| # | 功能 | 验收标准 | 证据 |
|---|---|---|---|
| F1 | 打开与渲染 | 打开显示正常,链接跳转,无外部请求 | 冒烟(强断言:`contentType==text/html` 且正文非空):`OPEN toc=78` → `SMOKE OK textLen>0`(chm:// 管线整读)。导航策略:仅 chm:// 站内加载;用户点击的 http(s) 链接转外部浏览器(iframe/重定向静默取消);WKContentRuleList 屏蔽全部 http(s) 子资源,落实离线。真机:首页"法术搜索快速跳转"等页内相对链接点击 → 书内跳转正常(lastPath 落盘证实) |
| F2 | 编码兼容 | 目录/正文/搜索无乱码 | GBK 基准:CLI `toc` 中文树全对(8514 项);冒烟渲染中文正文;单测 GBK/Big5/UTF-8/回退链 14 例;搜索索引与渲染统一按页嗅探 meta charset(CHMCharset.declared 下沉 Core) |
| F3 | 目录树 | 层级完整无乱码,点击导航,记住展开状态 | 冒烟 `OPEN toc=78`;递归 TOCNodeView——点标题导航/点箭头展开,真机点击验证 lastPath 变化;展开集合按书持久化(TOCExpansion/*.json,重启恢复,真机验证) |
| F4 | 索引页签 | 输入即时过滤 | 新书 .hhk 为真实索引(21 条,双 Name 形态):**修复**多 Name 时避开"书\章\词条"层级别名、取干净词条;真机验证索引页签显示"诀别遗物"并点击跳转 /荒洲探险家指南/荒洲宝藏/诀别遗物.html |
| F5 | 全文搜索 | 结果完整/跳转/高亮/排序合理 | 冒烟:`SEARCH q=法术 hits=200 total=2936 first=/万象无常书/小丑/法术卷轴.htm` → `HIGHLIGHT count=8` 跳转;标题命中优先 + 总数提示;**性能优化**:预计算小写正文 + 并发搜索,36MB 书 7028 页搜索 ~90ms(原 ~1.5s);索引构建 7028 页/16s 后台进行,缓存后即时 |
| F6 | 页内查找 | 上/下一个 | 冒烟:`FIND q=玩家 status=1/2`;JS 查询词改 JSON 字面量转义,含撇号查询 `Player's` 冒烟通过 |
| F7 | 多标签页 | 独立历史,同书多开 | 冒烟:`TABS independent=true tabs=2`;Cmd+T/W |
| F8 | 历史导航 | 前进/后退 | 冒烟:`HISTORY homeOK=true`;CHMHistory 单测 2 例 |
| F9 | 书签 | 增删/跳转/重启仍在 | CHMBookmarkStore 持久化单测(reload 断言);工具栏星标 + 侧栏管理 |
| F10 | 显示自定义 | 字体/字号/缩放持久化 | CHMSettingsStore 单测;**修复**:字号注入从 `*{...!important}` 改为 body 级,标题层级不再被压平;Cmd+=/-/0 |
| F11 | 状态记忆 | 重开恢复位置/最近打开 | 冒烟:`RESTORE ok=true`;recents 去重置顶单测;窗口尺寸/侧栏宽度由 SwiftUI 自动持久化 |
| F12 | 系统集成 | 双击 .chm 打开/拖放 | **修复**:WindowGroup→Window 单窗口架构,实测连续 `open -a` 窗口数恒为 1(旧版每次 open +1 且多窗口共享模型致空白正文);关窗即退;窗口 onDrop;DMG 挂载冒烟 |

## 第三轮复审记录(2026-09-26,基准书更换为 DND.26.09.13.chm)

- 基准书从 5R不全书(7.8MB,抓取站生成、站内链接写成源站绝对 URL)更换为 DND.26.09.13.chm(36.7MB,相对链接规范、真实 .hhk)。**回退**了第二轮针对旧书加的"https 外链按文件名回投"策略(LinkBack);http(s) 恢复为"点击转外部浏览器"。
- 新书暴露并修复:搜索性能(7028 页从 ~1.5s 优化到 ~90ms:预计算小写 + 并发);.hhk 双 Name 层级别名问题。
- 索引页签首次用真实索引数据验证通过。
- 已知:书中 192 个图床 https 图片被子资源拦截规则屏蔽(显示为破图),符合离线定位。

## 第二轮复审修复记录(2026-09-25)

第一轮验收后实测发现并已修复:多窗口灾难(P0)/目录树父节点不可点击(P0)/第二本书搜索索引陈旧(P0)/冒烟不可重复(状态污染)/无外链导航策略/JS 转义/字体压平/搜索无总数。新增:中英本地化(跟随系统,`CFBundleDevelopmentRegion=zh-Hans`,en.lproj 33 键,AX 实测双语切换)。冒烟状态隔离(CHIMERA_STATE_DIR),`scripts/smoke.sh` 连续运行可重复。

## 发布产物(dist/,不入库)

- `Chimera.app`(release 二进制 + AppIcon.icns + en/zh-Hans.lproj + ad-hoc 签名)
- `Chimera.dmg`(UDZO;hdiutil attach/detach 冒烟通过)
- `AppIcon.icns`(1024 源图 + 90% 安全边距 + 全套 iconset)

## 待用户人工确认项(视觉/手感,无法脚本化)

- [ ] 图标 16/32px 边缘辨识度(Finder 列表/标签栏)
- [ ] 侧栏/标签条视觉与拖放手感、深浅色外观
- [ ] 全书搜索结果列表阅读体验(摘要截断长度)

## 已知限制(v1.0)

- 未公证(Gatekeeper 首开需右键打开,README 有说明;PRD 排除公证)
- LCID 编码路径的 CHM(典型 Windows 老文件)经 allEntries 可读,entry(at:) 按名解析仅保证 UTF-8 路径容器(基准文件属此类);GBK 路径容器经侧栏/搜索导航可用
- Apple Silicon 单架构(本机 arm64;universal 构建需 rust 无关的简单 `--arch` 扩展,留待发布)
- 阅读位置记忆到页级,不记页内滚动偏移
- 书中图床(https)图片按离线策略屏蔽,显示为破图(设计如此)
