#!/bin/bash
# Chimera — run the full test suite.
#
# 本机为 CLT-only(无完整 Xcode):swift-testing 运行时存在,但其宏插件目录
# plugins/testing 未被 SPM 默认注册,必须显式加入编译器插件搜索路径。
# 见 docs/DEV_ENV.md。
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  "$@"
