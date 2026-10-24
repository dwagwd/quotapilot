# Template for a cask in a separate tap repository, e.g. dwagwd/homebrew-tap at Casks/quotapilot.rb.
# Use only with a Developer ID signed and notarized universal ZIP (see releasing.md).
# Users then install with: brew install --cask dwagwd/tap/quotapilot
cask "quotapilot" do
  version "0.4.0"
  sha256 "d0abbe31ffa0b73aab94354f40fde2fd8e3cda92065ef50194e0edf1f70bc58a"

  url "https://github.com/dwagwd/quotapilot/releases/download/v#{version}/QuotaPilot-#{version}-macos-universal.zip"
  name "QuotaPilot"
  desc "Floating desktop card for Codex plan quota, token usage and reset countdowns"
  homepage "https://github.com/dwagwd/quotapilot"

  depends_on macos: ">= :ventura"

  app "QuotaPilot.app"

  uninstall quit: "io.github.dwagwd.quotapilot"

  zap trash: [
    "~/Library/Application Support/QuotaPilot",
    "~/Library/Caches/QuotaPilot",
    "~/Library/Preferences/io.github.dwagwd.quotapilot.plist",
  ]
end
