#!/bin/bash
# Chimera — GUI 冒烟:串行跑 OPEN/NAV/SEARCH/FIND/HISTORY/TABS/RESTORE 全场景。
#
# 每场景使用独立的 CHIMERA_STATE_DIR(mktemp 临时目录),应用内所有持久化
# (设置/阅读状态/书签/目录展开/索引缓存)都被隔离,跑完即删,
# 不污染真实用户数据,连续多遍运行结果一致。任一场景失败即非零退出。
#
# 用法: ./scripts/smoke.sh            # 用默认验收书
#       CHIMERA_BOOK=/path/x.chm ./scripts/smoke.sh
set -u
cd "$(dirname "$0")/.."

BOOK="${CHIMERA_BOOK:-$HOME/Downloads/5R不全书（全扩展）2026.9.13.chm}"
BIN=".build/debug/ChimeraApp"
NAV_PATH="序章：欢迎来到冒险世界.htm"
SEARCH_Q="玩家"
FIND_Q="Player's"   # 含撇号,验证 JS 注入转义
TIMEOUT=120

if [ ! -f "$BOOK" ]; then
    echo "smoke: 找不到书: $BOOK (可用 CHIMERA_BOOK 指定)" >&2
    exit 2
fi
if [ ! -x "$BIN" ]; then
    echo "smoke: 先 swift build(缺 $BIN)" >&2
    exit 2
fi

overall=0

# run <场景名> [KEY=VALUE ...]
run() {
    local name="$1"; shift
    local statedir log pid wd rc
    statedir="$(mktemp -d "${TMPDIR:-/tmp/}chimera-smoke-$name.XXXXXX")"
    log="$statedir/app.log"

    env CHIMERA_SMOKE=1 CHIMERA_STATE_DIR="$statedir" CHIMERA_AUTO_OPEN="$BOOK" \
        "$@" "$BIN" >"$log" 2>&1 &
    pid=$!
    # 看门狗:WKWebView 卡死时强杀,避免脚本挂起
    ( sleep "$TIMEOUT"; kill "$pid" 2>/dev/null ) &
    wd=$!
    wait "$pid"; rc=$?
    kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null

    if [ "$rc" -eq 0 ]; then
        echo "PASS $name"
    else
        echo "FAIL $name (exit=$rc)"
        overall=1
    fi
    sed 's/^/    | /' "$log"
    rm -rf "$statedir"
}

run OPEN
run NAV     CHIMERA_NAV="$NAV_PATH"
run SEARCH  CHIMERA_SEARCH="$SEARCH_Q"
run FIND    CHIMERA_FIND="$FIND_Q"
run HISTORY CHIMERA_NAV="$NAV_PATH" CHIMERA_HISTORY=1
run TABS    CHIMERA_NAV="$NAV_PATH" CHIMERA_TABS=1
run RESTORE CHIMERA_NAV="$NAV_PATH" CHIMERA_RESTORE=1

echo
if [ "$overall" -eq 0 ]; then
    echo "smoke: 全部通过"
else
    echo "smoke: 存在失败场景"
fi
exit "$overall"
