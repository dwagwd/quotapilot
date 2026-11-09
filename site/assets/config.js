// Site config: sponsor link, install box, ads and affiliate links. Change values here, not in the HTML.
// To turn on ads later: set ads.enabled = true, add the network's script in index.html,
// and add its hosts to the Content-Security-Policy in _headers and the meta tag in index.html (scripts are limited to this site).
// To use affiliate links: put the tracking URL in affiliates.<provider>; empty = official pricing page.
window.SITE_CONFIG = {
  // Sponsor link shown in the nav, hero, support card, footer and the community invite.
  // Empty url hides every sponsor element. Only https:// URLs are used. Empty label = the translated default ("Sponsor").
  sponsor: { url: "", label: "" },  // set to the Polar/Ko-fi page when it exists (GitHub Sponsors does not pay out to Taiwan)
  // Homebrew install box (hero and community invite). The Copy button joins the lines with " && ".
  install: {
    commands: [
      "brew tap dwagwd/quotapilot https://github.com/dwagwd/quotapilot",
      "brew install dwagwd/quotapilot/quotapilot"
    ],
    // Command-line tool for the other systems. The Linux command picks x64 or arm64 itself, so the page never guesses the CPU; Windows gets the x64 build, which also runs on ARM PCs.
    platforms: {
      linux: ['curl -fsSL "https://github.com/dwagwd/quotapilot/releases/latest/download/quotapilot-linux-$(uname -m | sed \'s/x86_64/x64/;s/aarch64/arm64/\').tar.gz" | tar xz quotapilot'],
      windows: [
        'iwr "https://github.com/dwagwd/quotapilot/releases/latest/download/quotapilot-windows-x64.zip" -OutFile quotapilot.zip',
        "Expand-Archive quotapilot.zip -DestinationPath . -Force"
      ]
    },
    notesUrl: "https://github.com/dwagwd/quotapilot#install",
    sourceUrl: "https://github.com/dwagwd/quotapilot"
  },
  ads: {
    enabled: false // false = no ad slot is shown anywhere
  },
  affiliates: {
    chatgpt: "",
    claude: "",
    gemini: "",
    grok: ""
  },
  community: {
    // Anonymous collector (collector/ in the repo). Reports from the site form go here first.
    collector: "https://aiquotawatch.pages.dev/api",
    // Cloudflare Turnstile public site key for the report form. Empty = Turnstile off (the collector then never labels reports "site").
    // The script from challenges.cloudflare.com loads only when someone opens the report preview.
    turnstileSiteKey: ""
  },
  officialPricing: {
    chatgpt: "https://chatgpt.com/pricing",
    claude: "https://claude.com/pricing",
    gemini: "https://gemini.google/subscriptions/",
    grok: "https://x.ai/grok"
  }
};
