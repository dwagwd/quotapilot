// Monetization config. Nothing is connected yet.
// To turn on ads later: set ads.enabled = true, add the network's script in index.html,
// and add its hosts to the Content-Security-Policy meta tag there (scripts are limited to this site).
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
    grok: ""
  },
  community: {
    // Anonymous collector (collector/ in the repo). Reports from the site form go here first.
    collector: "https://quota-watch-collector.SUBDOMAIN.workers.dev",
    // Fallback: GitHub repo that receives reports as issues when the collector cannot be reached.
    repo: "dwagwd/quotapilot"
  },
  officialPricing: {
    chatgpt: "https://chatgpt.com/pricing",
    claude: "https://claude.com/pricing",
    gemini: "https://gemini.google/subscriptions/",
    grok: "https://x.ai/grok"
  }
};
