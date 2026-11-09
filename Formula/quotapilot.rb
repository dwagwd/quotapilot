# Homebrew formula. This repository is its own tap:
#   brew tap dwagwd/quotapilot https://github.com/dwagwd/quotapilot
#   brew install dwagwd/quotapilot/quotapilot
# QuotaPilot is built from source on your Mac (about two minutes) and ad-hoc signed there; no prebuilt
# binaries are published.
class Quotapilot < Formula
  desc "Desktop card and CLI for Codex and Claude Code plan quota, tokens and resets"
  homepage "https://github.com/dwagwd/quotapilot"
  url "https://github.com/dwagwd/quotapilot.git", tag: "v0.6.5", revision: "0000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/dwagwd/quotapilot.git", branch: "main"

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
      Start the desktop card:
        open #{opt_prefix}/QuotaPilot.app
      To find it in Spotlight and Launchpad, link it into Applications:
        ln -sf #{opt_prefix}/QuotaPilot.app ~/Applications/QuotaPilot.app
      Update later with:
        brew upgrade quotapilot
    EOS
  end

  test do
    assert_match "quotapilot", shell_output("#{bin}/quotapilot --help")
  end
end
