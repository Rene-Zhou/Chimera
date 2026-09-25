# 开发环境说明(DEV_ENV)

## 机器现状

- macOS(Apple Silicon),**仅安装 Command Line Tools(CLT)**,无完整 Xcode
- CLT 内置 Swift 6.4 + SDK MacOSX27.0,SPM 可用
- 验收基准文件:`~/Downloads/5R不全书（全扩展）2026.9.13.chm`(7.8MB,zh-CN/GBK)

## 测试框架:swift-testing(不是 XCTest)

CLT **不含 XCTest 模块**(XCTest 仅随完整 Xcode 分发),但**自带 swift-testing 运行时**:

- `Testing.framework` 位于 `/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
- 宏插件位于 `usr/lib/swift/host/plugins/testing/`(SPM 默认不注册该搜索路径)

因此运行测试必须注入插件路径(**`swift test` 不支持 `-Xfrontend` 透传,须用 `-Xswiftc`**):

```bash
./scripts/test.sh          # 等价于:
swift test -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

测试用例写法:`import Testing` + `@Test` + `#expect`(apple 新一代测试框架,满足目标契约中的 TDD 要求)。

## 已验证可行/不可行

| 事项 | 结论 |
|---|---|
| `swift build` / `swift run`(CLT 默认) | ✅ 可用 |
| `import Testing` 测试(CLT + 插件路径注入) | ✅ 可用,`./scripts/test.sh` |
| XCTest | ❌ CLT 无此模块,不使用 |
| `swift test -Xfrontend ...` | ❌ 不被识别(静默打印用法且退出码为 0,注意甄别假绿) |
| `TOOLCHAINS` 环境变量切换 swift.org 工具链 | ❌ 纯 CLT 下不生效(已试验并清理) |

## 注意事项

- 判断测试是否真正运行,输出必须包含 `Test run started` / `✔ ... passed`,不能只看退出码。
- 未来若安装完整 Xcode,可直接 `swift test`,无需上述旗标。

## 本地化(CLT 手工管线)

- 开发语言 = 简体中文(`defaultLocalization: "zh-Hans"`,Info.plist `CFBundleDevelopmentRegion=zh-Hans`),
  UI 字符串字面量本身即 localization key;翻译在 `Sources/ChimeraGUI/Resources/{en,zh-Hans}.lproj/`。
- SPM 将资源打进 `Chimera_ChimeraGUI.bundle`,但 SwiftUI `Text("key")`/`String(localized:)`
  **只查 main bundle**——裸二进制(.build/debug/ChimeraApp)main bundle 无资源,
  自动回退显示 key(即中文),冒烟/debug 不回归;.app 由 make-app.sh 把
  bundle 内 `.lproj` 平铺进 `Contents/Resources/`(嵌套 .bundle 不会被命中)。
- 三元/变量字符串(如 `Text(cond ? "a" : "b")`、`Text(stringVar)`)不走本地化,
  须拆成字面量分支或显式 `LocalizedStringKey(...)`。
- 打包后自检:`CHIMERA_L10N_PROBE=1 Chimera.app/Contents/MacOS/Chimera -AppleLanguages "(en)"`
  (注意必须数组语法,裸 `-AppleLanguages en` 无效)打印关键键的解析结果。
