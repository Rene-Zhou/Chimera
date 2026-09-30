#!/bin/bash
# Chimera — run the full test suite.
#
# 本机为 CLT-only(无完整 Xcode):swift-testing 运行时存在,但其宏插件目录
# plugins/testing 未被 SPM 默认注册,必须显式加入编译器插件搜索路径。
# 完整 Xcode 环境(CI 的 GitHub runner、装有 Xcode 的机器)则原生支持,
# 注入 CLT 路径反而可能加载到版本不匹配的宏插件。
# 这里按 xcode-select 当前指向自动分支。见 docs/DEV_ENV.md。
set -euo pipefail
cd "$(dirname "$0")/.."

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [ "$DEV_DIR" = "/Library/Developer/CommandLineTools" ]; then
    exec swift test \
        -Xswiftc -plugin-path \
        -Xswiftc "$DEV_DIR/usr/lib/swift/host/plugins/testing" \
        "$@"
else
    exec swift test "$@"
fi
