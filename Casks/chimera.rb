# 正本 cask:release.yml 在每次发版时自动更新 version/sha256,
# 并把本文件原样推送到 tap 仓库 Rene-Zhou/homebrew-tap(brew 安装入口)。
# 请勿手改 version/sha256/url 三行。
cask "chimera" do
  version "1.0.0"
  sha256 "aa4e881f11a6cc4d82569d0d03bcec2a2c67d9b8b3e4fa1e7eb6d839da0f72fc"

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
