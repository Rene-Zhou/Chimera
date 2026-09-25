# Chimera v1.0 验收走查(F1–F12)

基准文件:`~/Downloads/5R不全书（全扩展）2026.9.13.chm`(7.8MB,zh-CN/GBK,含 .hhc/.hhk/$FIftiMain)
测试:`./scripts/test.sh` **40/40 绿** · 走查日期:2026-09-25

| # | 功能 | 验收标准 | 证据 |
|---|---|---|---|
| F1 | 打开与渲染 | 打开显示正常,链接跳转,无外部请求 | 冒烟(强断言:`contentType==text/html` 且正文非空):`OPEN toc=29` → `SMOKE OK url=/序章：欢迎来到冒险世界.htm textLen=1113`(chm:// 管线整读)。注:初版断言仅查 innerText 长度,未能发现 mimeType 携带 charset 参数导致源码按纯文本显示的缺陷(用户实测抓出,fix 4268af0),已升级断言并修正 |
| F2 | 编码兼容 | 目录/正文/搜索无乱码 | GBK 基准:CLI `toc` 中文树全对;冒烟渲染中文正文;单测 GBK/Big5/UTF-8/回退链 8 例 |
| F3 | 目录树 | 层级完整无乱码,点击导航 | 冒烟 `OPEN toc=29`;CLI toc 输出(核心规则→玩家手册→序章→D20检定→豁免…);侧栏 List(children:) |
| F4 | 索引页签 | 输入即时过滤 | parseIndex+过滤 UI 就绪;基准 .hhk 为生成器空壳(数据本身无索引项,单测覆盖) |
| F5 | 全文搜索 | 结果完整/跳转/高亮 | 冒烟:`SEARCH q=法术 hits=100 first=/_金龙.htm` → `HIGHLIGHT count=1` → `textLen=9764`;索引 2123 页/5.9s,缓存后即时 |
| F6 | 页内查找 | 上/下一个 | 冒烟:`FIND q=玩家 status=1/3`(循环游标+计数+滚动) |
| F7 | 多标签页 | 独立历史,同书多开 | 冒烟:`TAB1 second=/第一章…`/`TAB2 home=/玩家手册…`/`TABS tab1Back=/玩家手册2024.htm independent=true tabs=2`;Cmd+T/W |
| F8 | 历史导航 | 前进/后退 | 冒烟:`HISTORY back=/玩家手册2024.htm homeOK=true`;CHMHistory 单测 2 例 |
| F9 | 书签 | 增删/跳转/重启仍在 | CHMBookmarkStore 持久化单测(reload 断言);工具栏星标 + 侧栏管理 |
| F10 | 显示自定义 | 字体/字号/缩放持久化 | CHMSettingsStore 单测;设置面板(单选+滑条即时生效);Cmd+=/-/0 |
| F11 | 状态记忆 | 重开恢复位置/最近打开 | 冒烟:`RESTORE restored=/第一章:进行游戏.htm ok=true`;recents 去重置顶单测 |
| F12 | 系统集成 | 双击 .chm 打开/拖放 | `open -a dist/Chimera.app <chm>` 启动运行(LaunchServices 打开事件路由);窗口 onDrop;Info.plist 声明 .chm Owner;DMG 挂载冒烟 `DMG=OK` |

## 发布产物(dist/,不入库)

- `Chimera.app`(release 二进制 + AppIcon.icns + ad-hoc 签名)
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
