# Homebrew formula. This repository is its own tap:
#   brew tap dwagwd/quotapilot https://github.com/dwagwd/quotapilot
#   brew install dwagwd/quotapilot/quotapilot
# When the formula has a `bottle do` block, Homebrew downloads that prebuilt package (built and ad-hoc signed
# on GitHub's runners, never on a personal machine). Otherwise, and on Macs the bottle does not cover,
# QuotaPilot is built from source on your Mac (about two minutes) and ad-hoc signed there.
class Quotapilot < Formula
  desc "Desktop card and CLI for Codex and Claude Code plan quota, tokens and resets"
  homepage "https://aiquotawatch.pages.dev/"
  url "https://github.com/dwagwd/quotapilot.git", tag: "v0.9.6", revision: "4efe1de9505540284562f5b599e545c75ed76567"
  license "MIT"
  head "https://github.com/dwagwd/quotapilot.git", branch: "main"

  bottle do
    root_url "https://github.com/dwagwd/quotapilot/releases/download/v0.9.6"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "6416d67cff54dff9432e8fdaa6ae4c82d17f3c667475fe9b2afa47bb465333bd"
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
      To also add a QuotaPilot entry to ~/Applications (Finder, Dock):
        quotapilot open --link
      Update later with:
        brew upgrade quotapilot
    EOS
  end

  test do
    assert_match "quotapilot", shell_output("#{bin}/quotapilot --help")
  end
end
