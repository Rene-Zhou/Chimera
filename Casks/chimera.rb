cask "chimera" do
  version "1.0.0"
  sha256 :no_check   # 本地验证用;正式发布替换为 DMG 实际 SHA256

  # 本地工件验证(发布时替换为 GitHub Release URL:
  # https://github.com/Rene-Zhou/Chimera/releases/download/v#{version}/Chimera.dmg)
  url "file:///Users/rene/Dev/Chimera/dist/Chimera.dmg"
  name "Chimera"
  desc "Modern native CHM reader for macOS"
  homepage "https://github.com/Rene-Zhou/Chimera"
  depends_on macos: ">= :sonoma"

  app "Chimera.app"

  zap trash: [
    "~/Library/Application Support/Chimera",
    "~/Library/Caches/Chimera",
  ]
end
