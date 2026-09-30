# Chimera

<p align="center">
  <img src="assets/icon/chimera-preview.png" width="128" alt="Chimera icon">
</p>

<p align="center">
  <b>现代原生 macOS CHM 阅读器 · A modern native CHM reader for macOS</b>
</p>

<p align="center">
  纯 Swift 编写(SwiftUI + AppKit + WKWebView),为阅读 TTRPG 规则书、技术文档等 CHM 资料而生。<br>
</p>

---

## 功能亮点 / Features

- **打开即读**:直接渲染 `.chm` 容器内资源,按需 LZX 解压,零磁盘解压、秒开大文件
- **中文不乱码**:GBK / Big5 / UTF-8 多级解码回退,自动识别书内 LCID
- **完整导航**:目录树、索引页签、全书搜索(标题 + 摘要,跳转后命中高亮)、页内查找(⌘F)
- **多标签页**:每个标签独立浏览历史,⌘T / ⌘W,同书多开,目录右键「在新标签页打开」
- **Safari 式前进/后退**:原生触控板双指滑动翻页,⌘[ / ⌘]
- **阅读不间断**:书签、重开恢复上次阅读位置(含滚动位置)、最近打开列表
- **排版自由**:字体、字号、行高、内容宽度自定义,⌘= / ⌘- / ⌘0 缩放,内容区独立深色模式
- **极速搜索**:全文索引磁盘缓存,二次打开即时可搜
- **中英双语界面**,跟随系统或手动切换

## 安装 / Install

从 [Releases](../../releases) 下载 `Chimera.dmg`,拖入「应用程序」。

> 未公证应用首次打开:右键 → 打开;或在终端执行
>
> ```bash
> xattr -d com.apple.quarantine /Applications/Chimera.app
> ```

Homebrew(正式发布后):

```bash
brew install --cask chimera
```

要求:macOS 14 Sonoma 或更高版本。

## 许可 / License

- 本体:[MIT](LICENSE) © 2026 Rene Zhou
- 内置 chmlib 0.40a:LGPL-2.1,源码随仓分发 — 详见 [`docs/THIRD_PARTY_NOTICES.md`](docs/THIRD_PARTY_NOTICES.md) 与 [`Sources/CChmlib/COPYING.LGPL`](Sources/CChmlib/COPYING.LGPL)
