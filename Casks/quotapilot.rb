# Homebrew cask. This repository is its own tap:
#   brew tap dwagwd/quotapilot https://github.com/dwagwd/quotapilot
#   brew install --cask dwagwd/quotapilot/quotapilot
# Point it only at a Developer ID signed and notarized universal ZIP (see docs/releasing.md).
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
