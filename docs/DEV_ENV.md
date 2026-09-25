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
