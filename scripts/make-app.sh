#!/bin/bash
# Chimera — 组装发布工件:.app(含图标)+ DMG(CLT-only,无 Xcode)
# 产物:dist/Chimera.app、dist/Chimera.dmg、dist/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."
DIST=dist
APP=$DIST/Chimera.app
ICONBUILD=$DIST/iconbuild

echo "== 1/4 release 构建 =="
swift build -c release --product ChimeraApp

echo "== 2/4 图标工业化(svg → iconset → icns)=="
rm -rf "$ICONBUILD" && mkdir -p "$ICONBUILD"
# cairosvg 渲染,保留透明通道(qlmanage 会把 SVG 透明画布拍成白底)。
# cairocffi 硬编码 cairo 库名,找不到 Homebrew 的 libcairo;
# 这里把 find_library 指到绝对路径。
# SVG 瓷砖本身已按 Apple 图标网格设计(896/1024、rx=200),不再二次缩边距——
# 旧管线的"90% 安全边距"会把已留白的图标再缩一圈,Dock 里明显偏小。
uv run --with cairosvg --with pillow python - <<'EOF'
import ctypes.util
_orig = ctypes.util.find_library
def _patched(name):
    if name and 'cairo' in name:
        return '/opt/homebrew/lib/libcairo.2.dylib'
    return _orig(name)
ctypes.util.find_library = _patched
import cairosvg
cairosvg.svg2png(url='assets/icon/chimera.svg', write_to='dist/iconbuild/icon_1024.png',
                 output_width=1024, output_height=1024)
# 同步刷新仓库预览图
cairosvg.svg2png(url='assets/icon/chimera.svg', write_to='assets/icon/chimera-preview.png',
                 output_width=1024, output_height=1024)
EOF
ICONSET="$ICONBUILD/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICONBUILD/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  d=$((size * 2)); [ "$d" -le 1024 ] && \
    sips -z "$d" "$d" "$ICONBUILD/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$DIST/AppIcon.icns"

echo "== 3/4 组装 .app + ad-hoc 签名 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ChimeraApp "$APP/Contents/MacOS/Chimera"
cp scripts/AppResources/Info.plist "$APP/Contents/Info.plist"
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# 本地化:SPM 资源 bundle 的 .lproj 平铺进 main bundle Resources——
# SwiftUI Text("key")/String(localized:) 只在 main bundle 查 Localizable.strings,
# 嵌套的 .bundle 不会被自动命中,故不拷 bundle 本体
RB=.build/release/Chimera_ChimeraGUI.bundle
if [ -d "$RB/Contents/Resources" ]; then
  cp -R "$RB/Contents/Resources/"*.lproj "$APP/Contents/Resources/"
else
  echo "警告: 未找到 SPM 资源 bundle ($RB),.app 将缺失本地化资源" >&2
fi
touch "$APP"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "== 4/4 DMG =="
rm -f "$DIST/Chimera.dmg"
hdiutil create -volname Chimera -srcfolder "$APP" -ov -format UDZO "$DIST/Chimera.dmg" >/dev/null
echo "DONE: $APP / $DIST/Chimera.dmg / $DIST/AppIcon.icns"
