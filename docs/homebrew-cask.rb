# Template for a cask in a separate tap repository, e.g. dwagwd/homebrew-tap at Casks/quotapilot.rb.
# Use only with a Developer ID signed and notarized universal ZIP (see releasing.md).
# Users then install with: brew install --cask dwagwd/tap/quotapilot
cask "quotapilot" do
  version "0.6.1"
  sha256 "6332273142eb16d91f3044d50d88b7780f8e00f99f08b2bb951b7969326e02be"

  url "https://github.com/dwagwd/quotapilot/releases/download/v#{version}/QuotaPilot-#{version}-macos-universal.zip"
  name "QuotaPilot"
  desc "Floating desktop card for Codex plan quota, token usage and reset countdowns"
  homepage "https://github.com/dwagwd/quotapilot"

  depends_on macos: ">= :ventura"
  # The app can update itself from the menu bar (after the user confirms).
  auto_updates true

  app "QuotaPilot.app"

  uninstall quit: "io.github.dwagwd.quotapilot"

  zap trash: [
    "~/Library/Application Support/QuotaPilot",
    "~/Library/Caches/QuotaPilot",
    "~/Library/Preferences/io.github.dwagwd.quotapilot.plist",
  ]
end
