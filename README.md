# Chimera 🐉📖

**现代原生 macOS CHM 阅读器 / A modern native CHM reader for macOS**

纯 Swift(SwiftUI + AppKit + WKWebView)。为阅读 TTRPG 规则书、技术文档等 CHM 资料而生。

## 功能 / Features

- 📂 打开渲染 `.chm`:GBK/Big5/UTF-8 多级解码回退,中文不乱码
- 🌲 目录树 / 索引页签 / **全书搜索**(标题+摘要,跳转后命中高亮)/ 页内查找(Cmd+F)
- 🗂 **多标签页**:每标签独立历史,Cmd+T/W,同书多开,目录右键"在新标签页打开"
- 🔖 书签 · 前进/后退(Cmd+[ / ])· **重开恢复上次阅读位置** · 最近打开
- 🔠 字体/字号自定义 · 缩放(Cmd+= / - / 0)
- ⚡️ 资源直接从容器按需 LZX 解压(零磁盘解压);全文索引磁盘缓存,二次打开即时搜索

## 安装 / Install

从 Releases 下载 `Chimera.dmg`,拖入"应用程序"。

> 未公证应用首次打开:右键 → 打开;或终端执行
> `xattr -d com.apple.quarantine /Applications/Chimera.app`

Homebrew(正式发布后):`brew install --cask chimera`

## 构建 / Build

仅需 Command Line Tools,**无需完整 Xcode**:

```bash
./scripts/test.sh      # 测试(swift-testing;需注入宏插件路径,见 docs/DEV_ENV.md)
./scripts/make-app.sh  # 产物:dist/Chimera.app + Chimera.dmg(+ AppIcon.icns)
```

## 许可 / License

- 本体:MIT(见 `LICENSE`)
- 内置 chmlib 0.40a:LGPL-2.1,源码随仓分发(见 `docs/THIRD_PARTY_NOTICES.md`、`Sources/CChmlib/COPYING.LGPL`)
