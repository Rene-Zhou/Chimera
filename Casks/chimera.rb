# 正本 cask:release.yml 在每次发版时自动更新 version/sha256,
# 并把本文件原样推送到 tap 仓库 Rene-Zhou/homebrew-tap(brew 安装入口)。
# 请勿手改 version/sha256/url 三行。
cask "chimera" do
  version "1.0.0"
  sha256 :no_check   # 发版流水线自动替换为 DMG 实际 SHA256

  url "https://github.com/Rene-Zhou/Chimera/releases/download/v#{version}/Chimera.dmg"
  name "Chimera"
  desc "Modern native CHM reader for macOS"
  homepage "https://github.com/Rene-Zhou/Chimera"
  depends_on macos: :sonoma

  app "Chimera.app"

  zap trash: [
    "~/Library/Application Support/Chimera",
    "~/Library/Caches/Chimera",
  ]
end
