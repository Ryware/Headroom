# Homebrew cask for Headroom. The release workflow fills in @VERSION@ and @SHA256@
# and pushes the result to the Ryware/homebrew-tap repository as Casks/headroom.rb.
cask "headroom" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/Ryware/Headroom/releases/download/v#{version}/Headroom-#{version}.dmg"
  name "Headroom"
  desc "Disk space analyser with treemap, safety guidance and developer cleanup"
  homepage "https://github.com/Ryware/Headroom"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Headroom.app"

  zap trash: [
    "~/Library/Application Support/Headroom",
    "~/Library/Caches/dev.ryware.disktree",
    "~/Library/HTTPStorages/dev.ryware.disktree",
    "~/Library/Preferences/dev.ryware.disktree.plist",
    "~/Library/Saved Application State/dev.ryware.disktree.savedState",
  ]
end
