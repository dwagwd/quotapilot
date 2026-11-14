# Homebrew formula. This repository is its own tap:
#   brew tap dwagwd/quotapilot https://github.com/dwagwd/quotapilot
#   brew install dwagwd/quotapilot/quotapilot
# When the formula has a `bottle do` block, Homebrew downloads that prebuilt package (built and ad-hoc signed
# on GitHub's runners, never on a personal machine). Otherwise, and on Macs the bottle does not cover,
# QuotaPilot is built from source on your Mac (about two minutes) and ad-hoc signed there.
class Quotapilot < Formula
  desc "Desktop card and CLI for Codex and Claude Code plan quota, tokens and resets"
  homepage "https://aiquotawatch.pages.dev/"
  url "https://github.com/dwagwd/quotapilot.git", tag: "v0.6.7", revision: "de4ac240bacc7c9c4ddf4b5d10c93fc22088b3cc"
  license "MIT"
  head "https://github.com/dwagwd/quotapilot.git", branch: "main"

  bottle do
    root_url "https://github.com/dwagwd/quotapilot/releases/download/v0.6.7"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "f6d2d8b860fb29cea549697531402b100b29fa09c7439be5b8b6fad8456b5d50"
  end

  depends_on macos: :ventura

  def install
    ENV["QUOTAPILOT_BUILD_CACHE"] = (buildpath/".build").to_s
    ENV["QUOTAPILOT_DIST_DIR"] = (buildpath/"dist").to_s
    # Homebrew already sandboxes the build; SwiftPM cannot start a second sandbox inside it.
    ENV["QUOTAPILOT_SWIFTPM_ARGS"] = "--disable-sandbox"
    system "scripts/build.sh"
    prefix.install "dist/QuotaPilot.app"
    bin.install_symlink prefix/"QuotaPilot.app/Contents/Helpers/quotapilot"
  end

  def caveats
    <<~EOS
      Start the menu bar app:
        quotapilot open
      To also find it in Spotlight and Launchpad:
        quotapilot open --link
      Update later with:
        brew upgrade quotapilot
    EOS
  end

  test do
    assert_match "quotapilot", shell_output("#{bin}/quotapilot --help")
  end
end
