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

echo "== 2/4 图标工业化(svg → 安全边距 → iconset → icns)=="
rm -rf "$ICONBUILD" && mkdir -p "$ICONBUILD"
qlmanage -t -s 1024 -o "$ICONBUILD" assets/icon/chimera.svg >/dev/null 2>&1
mv "$ICONBUILD/chimera.svg.png" "$ICONBUILD/raw_1024.png"
# Apple 图标网格安全边距:内容缩至 90% 居中于透明画布
uv run --with pillow python - <<'EOF'
from PIL import Image
im = Image.open('dist/iconbuild/raw_1024.png').convert('RGBA')
canvas = Image.new('RGBA', im.size, (0, 0, 0, 0))
side = int(im.width * 0.90)
inner = im.resize((side, side), Image.LANCZOS)
canvas.paste(inner, ((im.width - side) // 2, (im.height - side) // 2))
canvas.save('dist/iconbuild/safe_1024.png')
EOF
ICONSET="$ICONBUILD/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICONBUILD/safe_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  d=$((size * 2)); [ "$d" -le 1024 ] && \
    sips -z "$d" "$d" "$ICONBUILD/safe_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
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
