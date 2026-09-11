/**
 * Client personas for exercising Obsero's header-based classification.
 *
 * Each persona sends the header set that client really sends, because that is
 * the only part of the request the analytics endpoint gets to classify on.
 * `kind` is what we expect Obsero to conclude, so a run can be scored.
 *
 *   ai-agent   - fetching live, on behalf of a person asking a question now
 *   ai-crawler - bulk crawling for training/indexing, no human waiting
 *   search-bot - classic search engine indexer
 *   human      - a real browser
 */

const CH = (brands, platform, mobile = "?0") => ({
  "sec-ch-ua": brands,
  "sec-ch-ua-mobile": mobile,
  "sec-ch-ua-platform": platform,
});

const BROWSER_ACCEPT =
  "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8";

const NAV = {
  "sec-fetch-dest": "document",
  "sec-fetch-mode": "navigate",
  "sec-fetch-site": "none",
  "sec-fetch-user": "?1",
  "upgrade-insecure-requests": "1",
};

export const PERSONAS = [
  // ---------------------------------------------------------------- humans --
  {
    id: "chrome-windows",
    label: "Chrome 133 / Windows 11",
    kind: "human",
    weight: 10,
    headers: {
      "user-agent":
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36",
      accept: BROWSER_ACCEPT,
      "accept-language": "en-US,en;q=0.9",
      "accept-encoding": "gzip, deflate, br, zstd",
      ...CH('"Not(A:Brand";v="99", "Google Chrome";v="133", "Chromium";v="133"', '"Windows"'),
      ...NAV,
    },
  },
  {
    id: "safari-iphone",
    label: "Safari / iPhone iOS 18",
    kind: "human",
    weight: 6,
    headers: {
      "user-agent":
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1",
      accept: BROWSER_ACCEPT,
      "accept-language": "en-GB,en;q=0.9",
      "accept-encoding": "gzip, deflate, br",
    },
  },
  {
    id: "firefox-macos",
    label: "Firefox 135 / macOS",
    kind: "human",
    weight: 4,
    headers: {
      "user-agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:135.0) Gecko/20100101 Firefox/135.0",
      accept: BROWSER_ACCEPT,
      "accept-language": "en-US,en;q=0.5",
      "accept-encoding": "gzip, deflate, br, zstd",
      dnt: "1",
      ...NAV,
    },
  },
  {
    id: "chrome-android",
    label: "Chrome / Android 15",
    kind: "human",
    weight: 4,
    headers: {
      "user-agent":
        "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Mobile Safari/537.36",
      accept: BROWSER_ACCEPT,
      "accept-language": "en-US,en;q=0.9",
      "accept-encoding": "gzip, deflate, br, zstd",
      ...CH('"Not(A:Brand";v="99", "Google Chrome";v="133", "Chromium";v="133"', '"Android"', "?1"),
      ...NAV,
    },
  },

  // ------------------------------------------------------------- ai agents --
  // Live fetches with a human waiting. These are the ones an agent-analytics
  // product most wants to separate from bulk crawlers.
  {
    id: "chatgpt-user",
    label: "ChatGPT-User (live browse)",
    kind: "ai-agent",
    vendor: "openai",
    weight: 9,
    headers: {
      "user-agent":
        "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot",
      accept: "*/*",
      "accept-encoding": "gzip, deflate",
      // Web Bot Auth: how OpenAI proves a live fetch is really theirs.
      "signature-agent": '"https://chatgpt.com"',
      "signature-input":
        'sig1=("@authority" "signature-agent");created=1750000000;keyid="poqkLGiymh_W0uP6PZFw-dvez3QJT5SolqXBCW38r0U";alg="ed25519";expires=1750000600;nonce="mock-nonce"',
      signature: "sig1=:bW9ja2VkLXNpZ25hdHVyZS1ub3QtcmVhbC1qdXN0LWZvci1zaGFwZQ==:",
    },
  },
  {
    id: "claude-user",
    label: "Claude-User (live browse)",
    kind: "ai-agent",
    vendor: "anthropic",
    weight: 7,
    headers: {
      "user-agent":
        "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; Claude-User/1.0; +Claude-User@anthropic.com",
      accept: "*/*",
      "accept-encoding": "gzip, deflate",
    },
  },
  {
    id: "perplexity-user",
    label: "Perplexity-User (live browse)",
    kind: "ai-agent",
    vendor: "perplexity",
    weight: 6,
    headers: {
      "user-agent":
        "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; Perplexity-User/1.0; +https://perplexity.ai/perplexity-user",
      accept: "*/*",
      "accept-encoding": "gzip, deflate",
    },
  },
  {
    id: "oai-searchbot",
    label: "OAI-SearchBot (search index)",
    kind: "ai-agent",
    vendor: "openai",
    weight: 5,
    headers: {
      "user-agent":
        "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; OAI-SearchBot/1.0; +https://openai.com/searchbot",
      accept: "*/*",
      "accept-encoding": "gzip, deflate",
    },
  },
  {
    id: "duckassist",
    label: "DuckAssistBot",
    kind: "ai-agent",
    vendor: "duckduckgo",
    weight: 2,
    headers: {
      "user-agent":
        "Mozilla/5.0 (compatible; DuckAssistBot/1.0; +https://duckduckgo.com/duckassistbot)",
      accept: "*/*",
      "accept-encoding": "gzip, deflate",
    },
  },

  // ----------------------------------------------------------- ai crawlers --
  {
    id: "gptbot",
    label: "GPTBot (training crawl)",
    kind: "ai-crawler",
    vendor: "openai",
    weight: 8,
    headers: {
      "user-agent":
        "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; GPTBot/1.2; +https://openai.com/gptbot",
      accept: "*/*",
      "accept-encoding": "gzip, deflate",
      from: "gptbot(at)openai.com",
    },
  },
  {
    id: "claudebot",
    label: "ClaudeBot (training crawl)",
    kind: "ai-crawler",
    vendor: "anthropic",
    weight: 6,
    headers: {
      "user-agent":
        "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ClaudeBot/1.0; +claudebot@anthropic.com",
      accept: "*/*",
      "accept-encoding": "gzip, deflate",
    },
  },
  {
    id: "perplexitybot",
    label: "PerplexityBot",
    kind: "ai-crawler",
    vendor: "perplexity",
    weight: 4,
    headers: {
      "user-agent":
        "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot",
      accept: "*/*",
      "accept-encoding": "gzip, deflate",
    },
  },
  {
    id: "meta-externalagent",
    label: "Meta-ExternalAgent",
    kind: "ai-crawler",
    vendor: "meta",
    weight: 3,
    headers: {
      "user-agent":
        "meta-externalagent/1.1 (+https://developers.facebook.com/docs/sharing/webmasters/crawler)",
      accept: "*/*",
      "accept-encoding": "gzip, deflate",
    },
  },
  {
    id: "bytespider",
    label: "Bytespider (ByteDance)",
    kind: "ai-crawler",
    vendor: "bytedance",
    weight: 3,
    headers: {
      "user-agent":
        "Mozilla/5.0 (Linux; Android 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 (compatible; Bytespider; spider-feedback@bytedance.com)",
      accept: "*/*",
      "accept-encoding": "gzip, deflate",
    },
  },
  {
    id: "ccbot",
    label: "CCBot (Common Crawl)",
    kind: "ai-crawler",
    vendor: "commoncrawl",
    weight: 2,
    headers: {
      "user-agent": "CCBot/2.0 (https://commoncrawl.org/faq/)",
      accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "accept-encoding": "gzip, deflate",
    },
  },
  {
    id: "amazonbot",
    label: "Amazonbot",
    kind: "ai-crawler",
    vendor: "amazon",
    weight: 2,
    headers: {
      "user-agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 (compatible; Amazonbot/0.1; +https://developer.amazon.com/support/amazonbot)",
      accept: "*/*",
      "accept-encoding": "gzip, deflate",
    },
  },

  // ---------------------------------------------------------- search bots ---
  {
    id: "googlebot",
    label: "Googlebot",
    kind: "search-bot",
    vendor: "google",
    weight: 5,
    headers: {
      "user-agent":
        "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Googlebot/2.1; +http://www.google.com/bot.html) Chrome/133.0.0.0 Safari/537.36",
      accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "accept-encoding": "gzip, deflate, br",
      from: "googlebot(at)googlebot.com",
    },
  },
  {
    id: "bingbot",
    label: "Bingbot",
    kind: "search-bot",
    vendor: "microsoft",
    weight: 3,
    headers: {
      "user-agent":
        "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm) Chrome/116.0.1938.76 Safari/537.36",
      accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "accept-encoding": "gzip, deflate, br",
    },
  },
  {
    id: "applebot",
    label: "Applebot",
    kind: "search-bot",
    vendor: "apple",
    weight: 2,
    headers: {
      "user-agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 (Applebot/0.1; +http://www.apple.com/go/applebot)",
      accept: BROWSER_ACCEPT,
      "accept-encoding": "gzip, deflate, br",
    },
  },
];

export const KINDS = ["human", "ai-agent", "ai-crawler", "search-bot"];

export function byId(id) {
  return PERSONAS.find((p) => p.id === id);
}
