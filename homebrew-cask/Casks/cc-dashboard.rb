# Homebrew Cask for cc-dashboard.
#
# 这个文件是**模板**,真实的分发入口需要单独建一个 GitHub repo:
#   github.com/heypandax/homebrew-cc-dashboard
# 把本文件拷贝到那个 repo 的 Casks/cc-dashboard.rb,之后用户就能:
#   brew tap heypandax/cc-dashboard
#   brew install --cask cc-dashboard
#
# 每次发新版:更新 version + sha256(DMG 的 shasum -a 256),commit + push tap repo 即可。

cask "cc-dashboard" do
  version "0.1.8"
  sha256 "ab4e490c243cb42455d0504d60ce330d5ec33532d7009514f373a91bbcece036"

  url "https://github.com/heypandax/cc-dashboard/releases/download/v#{version}/cc-dashboard.dmg"
  name "Claude Code Dashboard"
  desc "Menu bar companion for concurrent Claude Code sessions"
  homepage "https://github.com/heypandax/cc-dashboard"

  livecheck do
    url "https://heypandax.github.io/cc-dashboard/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "cc-dashboard.app"

  zap trash: [
    "~/Library/Application Support/cc-dashboard",
    "~/Library/Logs/cc-dashboard",
    "~/Library/LaunchAgents/com.heypanda.cc-dashboard.plist",
  ]
end
