// Monetization config. Nothing is connected yet.
// To turn on ads later: set ads.enabled = true and add the network's script in index.html.
// To use affiliate links: put the tracking URL in affiliates.<provider>; empty = official pricing page.
window.SITE_CONFIG = {
  ads: {
    enabled: false,       // false = slots stay as dashed placeholders in dev, hidden in production
    showPlaceholders: false // true shows dashed boxes where ads will go (for layout previews)
  },
  affiliates: {
    chatgpt: "",
    claude: "",
    gemini: "",
    grok: "",
    cursor: "",
    antigravity: ""
  },
  community: {
    // GitHub repo that receives reports as issues (the QuotaPilot repo hosts the site and its data).
    // Set to "" to show the report JSON with a copy button instead.
    repo: "dwagwd/quotapilot"
  },
  officialPricing: {
    chatgpt: "https://chatgpt.com/pricing",
    claude: "https://claude.com/pricing",
    gemini: "https://gemini.google/subscriptions/",
    grok: "https://x.ai/grok",
    cursor: "https://cursor.com/pricing",
    antigravity: "https://antigravity.google/docs/plans"
  }
};
