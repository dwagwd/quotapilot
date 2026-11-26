// Model ranking logic shared by the static page builder (scripts/models-pages.mjs, run in Node) and the browser (assets/models-page.js).
// Plain functions and HTML renderers only: no DOM access, no network, so the same code produces the static table and the interactive one.
// Third-party benchmark scores are not stored or shown anywhere. The "smartness" column below exists as an empty, hidden slot until a source
// with a licence that allows it is added (see SMARTNESS and scripts/validate-data.mjs, which forbids such fields in data/models.json).
(function (root) {
  "use strict";

  // The mix behind "blended" prices: 3 input tokens for every output token, list prices, no cache.
  const BLEND = { input: 3, output: 1 };
  // No licensed source yet: nothing is read, stored or shown. Flip only together with a licensed data source.
  const SMARTNESS = { enabled: false };

  const PROVIDERS = { chatgpt: "OpenAI (GPT)", claude: "Anthropic (Claude)", gemini: "Google (Gemini)", grok: "xAI (Grok)" };
  const ENGINES = { ollama: "Ollama", lmstudio: "LM Studio", llamacpp: "llama.cpp", omlx: "oMLX", strata: "Strata", mlx: "MLX", vllm: "vLLM", other: "Other" };

  const STRINGS = {
    en: {
      title: "LLM ranking: API price, speed and cost per model",
      h1: "LLM ranking: price, speed and what it costs you",
      desc: "Every cloud model's API price, context length and community-measured output speed, and local models by chip, memory and engine, with a calculator for your own monthly cost and electricity.",
      intro: "Cloud models at vendor list prices (USD per million tokens) and local models measured by QuotaPilot users who chose to share their speed. Pick filters, sort any column, then enter your own numbers below to see what each option would cost you per month.",
      fType: "Type", fAll: "All", fCloud: "Cloud", fLocal: "Local", fProvider: "Provider", fBudget: "Max blended price per 1M tokens (USD)", fChip: "My chip", fMem: "My memory", fAny: "Any",
      fReset: "Reset filters", showing: "Showing {n} of {m} rows",
      cType: "Type", cModel: "Model", cProvider: "Provider, or engine and hardware", cInput: "Input $/1M", cOutput: "Output $/1M", cCache: "Cache read $/1M", cBlended: "Blended $/1M",
      cContext: "Context", cSpeed: "Speed (tok/s)", cRating: "How it feels", cSmart: "Smartness", cElec: "Electricity per 1M output",
      typeCloud: "Cloud", typeLocal: "Local",
      people1: "1 person", peopleN: "{n} people", prelim: "preliminary", ratingOf: "{v}/10",
      none: "—", noData: "no data yet",
      blendNote: "Blended = 3 input tokens for every output token at list price, without cache discounts. Cloud prices are USD list prices; local models have no API price, only electricity.",
      speedNote: "Speed is output tokens per second measured by QuotaPilot users who chose to share it (median of people, not of calls); a row appears from 3 people, and 1-2 people give a rounded preliminary figure. Local speeds depend on chip, memory, engine and quantization.",
      smartNote: "Model quality is not ranked here: no third-party benchmark numbers are stored or shown.",
      calcTitle: "What fits me",
      calcIntro: "Enter how much you use per month, or paste your own usage from QuotaPilot. Everything is calculated in this page; nothing is uploaded.",
      inTok: "Input tokens per month (millions)", outTok: "Output tokens per month (millions)", cachedShare: "Share of input served from cache (%)",
      paste: "Or paste the output of: quotapilot stats --json", pasteUse: "Use these numbers", pasteOk: "Read {hours} h of usage: {inM}M input, {outM}M output tokens per month.", pasteBad: "That does not look like quotapilot stats --json output.",
      numbers: "Your numbers", currency: "Currency", rate: "Exchange rate: 1 USD =", kwh: "Electricity price per kWh", watts: "Computer power (W)", hours: "Hours of use per day",
      rateHelp: "Cloud prices are in USD. Without an exchange rate, other currencies show USD for cloud models.",
      wattsHelp: "Apple chips draw about 20 W (base), 40 W (Pro), 70 W (Max) and 120 W (Ultra) under load; other computers often 100 W or more. This is an estimate: enter your own figure if you know it.",
      resTitle: "Monthly cost for your usage", resModel: "Model", resCost: "Cost per month", resSpeed: "Speed (tok/s)", resTime: "Generation time per month",
      resNeedPrice: "enter electricity price", resNoElec: "Enter an electricity price to price local models.", resNoRate: "USD (no exchange rate set)", resOutputOnly: "Local cost counts generation time (and prompt time where the prompt speed is known).",
      hoursUnit: "{v} h",
      elecTitle: "Electricity calculator", elecIntro: "What does it cost to run a model on your own computer? Uses the price, power and hours above.",
      elecSpeed: "Generation speed (tokens per second)", elecCompare: "Compare with cloud model", elecKwh: "Energy per month", elecMonth: "Electricity per month", elecTokens: "Tokens generated per month if it runs that long",
      elecPerM: "Electricity per 1M output tokens", elecCloudPerM: "{name}: output price per 1M tokens", elecVerdict: "Electricity costs {x} times {dir} per output token than that cloud model.", dirLess: "less", dirMore: "more",
      elecNeed: "Enter an electricity price, power, hours and a speed.", elecFootnote: "Assumes the computer generates tokens the whole time it is on; idle time and prompt processing are not counted.",
      chipsTitle: "Local LLM speed by Mac chip", chipsDesc: "How fast local models run on each Apple chip, measured by QuotaPilot users who chose to share: tokens per second by model, quantization, engine and memory.",
      chipsH1: "Local LLM speed by Mac chip", chipsIntro: "Measured generation speed of local models on Apple silicon, by chip, memory, engine and quantization. Only real measurements from QuotaPilot users who chose to share are listed; a row needs 3 people.",
      chipsEmptyTitle: "No community measurements yet", chipsEmpty: "Nobody has shared local model speeds yet, so there is nothing honest to show here. This page fills in on its own once at least 3 people share the same combination of model, engine, chip and memory.",
      chipsHow: "How to contribute", chipsHow1: "Install QuotaPilot and switch on local model counting (Ollama, LM Studio, llama.cpp, oMLX).", chipsHow2: "Use your local model for a while; QuotaPilot measures tokens per second.", chipsHow3: "Opt in to sharing local model speed (off by default). It shows exactly what would be sent first: model name, size, quantization, engine, chip, memory tier and speed.",
      chipsCmd: "quotapilot local config on\nquotapilot share --only localRuns",
      chipsGen: "Generation tok/s", chipsPrompt: "Prompt tok/s", chipsPeople: "People", chipsQuant: "Quant", chipsEngine: "Engine", chipsMemory: "Memory", chipsChip: "Chip", chipsPrelimTitle: "Preliminary (1-2 people)",
      chipsPrelimNote: "Rounded to the nearest 5 tok/s; not yet a published row.", chipsAsOf: "Community data generated {d}.",
      pricesTitle: "LLM API price comparison", pricesDesc: "Input, output and cached-input prices per million tokens for GPT, Claude, Gemini and Grok models, with context length and the vendor page each price comes from.",
      pricesH1: "LLM API price comparison (USD per million tokens)", pricesIntro: "List prices for the current OpenAI, Anthropic, Google and xAI API models, cheapest blended price first. Every price links to the vendor's own page and carries the date it was checked.",
      pricesSource: "Source", pricesChecked: "checked", pricesFaqQ1: "Which API model is cheapest?", pricesFaqA1: "{name} at {price} per million tokens blended (3 input : 1 output) is the cheapest listed here.", pricesFaqQ2: "What is a blended price?", pricesFaqA2: "The price of one million tokens when three of every four are input and one is output, at list price and without cache discounts.", pricesFaqQ3: "Do cached tokens cost less?", pricesFaqA3: "Yes. Models with a cache-read price charge that lower price for input tokens served from the prompt cache.",
      pricesWritePrice: "Cache write $/1M",
      linkRanking: "Full ranking and calculator", linkChips: "Local LLM speed by Mac chip", linkPrices: "LLM API price comparison",
      checked: "Prices checked", dataAsOf: "Community data generated", noscript: "The table works without JavaScript; filters and calculators need it."
    },
    zh: {
      title: "LLM 排行榜：各模型 API 價格、速度與費用",
      h1: "LLM 排行榜：價格、速度，以及你要花多少",
      desc: "所有雲端模型的 API 價格、上下文長度與社群實測輸出速度，以及依晶片、記憶體和推論引擎分組的本機模型，還有可算出你每月費用與電費的計算器。",
      intro: "雲端模型用官方牌價（每百萬 token 美元），本機模型則是自願分享速度的 QuotaPilot 使用者實測。先篩選、排序，再在下方輸入你自己的用量，看每個選項每月要花多少。",
      fType: "類型", fAll: "全部", fCloud: "雲端", fLocal: "本機", fProvider: "供應商", fBudget: "每百萬 token 混合價上限（美元）", fChip: "我的晶片", fMem: "我的記憶體", fAny: "不限",
      fReset: "重設篩選", showing: "顯示 {n} / {m} 列",
      cType: "類型", cModel: "模型", cProvider: "供應商，或引擎與硬體", cInput: "輸入 $/百萬", cOutput: "輸出 $/百萬", cCache: "快取讀取 $/百萬", cBlended: "混合價 $/百萬",
      cContext: "上下文", cSpeed: "速度（tok/s）", cRating: "使用體感", cSmart: "智力", cElec: "每百萬輸出電費",
      typeCloud: "雲端", typeLocal: "本機",
      people1: "1 人", peopleN: "{n} 人", prelim: "初步", ratingOf: "{v}/10",
      none: "—", noData: "尚無資料",
      blendNote: "混合價＝每 1 個輸出 token 配 3 個輸入 token，依牌價計算，不含快取折扣。雲端價格為美元牌價；本機模型沒有 API 價格，只有電費。",
      speedNote: "速度是自願分享的 QuotaPilot 使用者實測的每秒輸出 token（取「人」的中位數，而非呼叫次數）；滿 3 人才出現一列，1–2 人只顯示取整的初步數字。本機速度取決於晶片、記憶體、引擎與量化。",
      smartNote: "這裡不排名模型品質：不儲存也不顯示任何第三方測驗分數。",
      calcTitle: "適合我的選擇",
      calcIntro: "輸入你每月的用量，或貼上 QuotaPilot 量到的實際用量。全部在這個頁面內計算，不會上傳任何資料。",
      inTok: "每月輸入 token（百萬）", outTok: "每月輸出 token（百萬）", cachedShare: "輸入中由快取提供的比例（%）",
      paste: "或貼上這個指令的輸出：quotapilot stats --json", pasteUse: "使用這些數字", pasteOk: "讀到 {hours} 小時的用量：每月約 {inM}M 輸入、{outM}M 輸出 token。", pasteBad: "這看起來不是 quotapilot stats --json 的輸出。",
      numbers: "你的數字", currency: "幣別", rate: "匯率：1 USD =", kwh: "每度電價", watts: "電腦功率（W）", hours: "每天使用小時數",
      rateHelp: "雲端價格以美元計。沒有填匯率時，雲端模型在其他幣別下仍顯示美元。",
      wattsHelp: "Apple 晶片滿載約 20 W（基本款）、40 W（Pro）、70 W（Max）、120 W（Ultra）；其他電腦常在 100 W 以上。這是估算，知道實際數字請自行填寫。",
      resTitle: "依你的用量算出的每月費用", resModel: "模型", resCost: "每月費用", resSpeed: "速度（tok/s）", resTime: "每月生成時間",
      resNeedPrice: "請輸入電價", resNoElec: "輸入每度電價，才能替本機模型估價。", resNoRate: "美元（未設定匯率）", resOutputOnly: "本機費用只計算生成時間（已知提示速度時也計入提示處理時間）。",
      hoursUnit: "{v} 小時",
      elecTitle: "電費計算器", elecIntro: "在自己的電腦上跑模型要花多少電費？使用上方的電價、功率與使用時數。",
      elecSpeed: "生成速度（每秒 token）", elecCompare: "與雲端模型比較", elecKwh: "每月用電量", elecMonth: "每月電費", elecTokens: "若一直在跑，每月生成的 token 數",
      elecPerM: "每百萬輸出 token 電費", elecCloudPerM: "{name}：每百萬 token 輸出價", elecVerdict: "每個輸出 token 的電費比該雲端模型{dir} {x} 倍。", dirLess: "便宜", dirMore: "貴",
      elecNeed: "請輸入電價、功率、使用時數與速度。", elecFootnote: "假設電腦開機期間一直在生成 token；閒置時間與提示處理不計入。",
      chipsTitle: "各款 Mac 晶片的本機 LLM 速度", chipsDesc: "本機模型在各款 Apple 晶片上跑多快：由自願分享的 QuotaPilot 使用者實測，依模型、量化、引擎與記憶體列出每秒 token 數。",
      chipsH1: "各款 Mac 晶片的本機 LLM 速度", chipsIntro: "Apple silicon 上本機模型的實測生成速度，依晶片、記憶體、引擎與量化分組。只列出自願分享的 QuotaPilot 使用者的真實量測；同一組合要有 3 個人才會出現一列。",
      chipsEmptyTitle: "目前還沒有社群量測資料", chipsEmpty: "還沒有人分享本機模型速度，所以這裡沒有可誠實顯示的內容。只要有至少 3 個人分享同一組「模型、引擎、晶片、記憶體」，這個頁面就會自動出現資料。",
      chipsHow: "如何貢獻", chipsHow1: "安裝 QuotaPilot，並開啟本機模型統計（Ollama、LM Studio、llama.cpp、oMLX）。", chipsHow2: "正常使用本機模型一段時間，QuotaPilot 會量測每秒 token。", chipsHow3: "選擇加入分享本機模型速度（預設關閉）。送出前會先顯示完整內容：模型名稱、大小、量化、引擎、晶片、記憶體級距與速度。",
      chipsCmd: "quotapilot local config on\nquotapilot share --only localRuns",
      chipsGen: "生成 tok/s", chipsPrompt: "提示 tok/s", chipsPeople: "人數", chipsQuant: "量化", chipsEngine: "引擎", chipsMemory: "記憶體", chipsChip: "晶片", chipsPrelimTitle: "初步資料（1–2 人）",
      chipsPrelimNote: "取整到最接近的 5 tok/s；尚未成為正式公布的一列。", chipsAsOf: "社群資料產生於 {d}。",
      pricesTitle: "LLM API 價格比較", pricesDesc: "GPT、Claude、Gemini、Grok 模型每百萬 token 的輸入、輸出與快取輸入價格，附上下文長度與每個價格的官方來源頁。",
      pricesH1: "LLM API 價格比較（每百萬 token，美元）", pricesIntro: "OpenAI、Anthropic、Google、xAI 目前 API 模型的牌價，混合價由低到高。每個價格都連到官方頁面並附查證日期。",
      pricesSource: "來源", pricesChecked: "查證於", pricesFaqQ1: "哪個 API 模型最便宜？", pricesFaqA1: "這裡列出的模型中，{name} 的混合價（3 輸入：1 輸出）每百萬 token {price} 最便宜。", pricesFaqQ2: "什麼是混合價？", pricesFaqA2: "每 4 個 token 中有 3 個輸入、1 個輸出時，一百萬 token 的牌價，不含快取折扣。", pricesFaqQ3: "快取的 token 比較便宜嗎？", pricesFaqA3: "是。有快取讀取價的模型，由提示快取提供的輸入 token 會用這個較低的價格計費。",
      pricesWritePrice: "快取寫入 $/百萬",
      linkRanking: "完整排行與計算器", linkChips: "各款 Mac 晶片的本機 LLM 速度", linkPrices: "LLM API 價格比較",
      checked: "價格查證於", dataAsOf: "社群資料產生於", noscript: "表格不需要 JavaScript 就能閱讀；篩選與計算器需要。"
    }
  };

  const T = (lang) => STRINGS[lang === "zh" ? "zh" : "en"];
  const fill = (s, vars) => String(s).replace(/\{(\w+)\}/g, (m, k) => (vars && vars[k] != null ? vars[k] : m));
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  // ---------- numbers ----------
  const usd = (v) => (v == null || !Number.isFinite(v) ? "—" : v === 0 ? "$0" : "$" + (Math.abs(v) >= 100 ? v.toFixed(0) : (Math.round(v * 100) / 100).toFixed(2).replace(/\.00$/, "")));
  const contextTokens = (s) => {
    const m = /^([0-9.]+)\s*([KkMm])?$/.exec(String(s || "").trim());
    return m ? Number(m[1]) * (m[2] ? (m[2].toLowerCase() === "m" ? 1e6 : 1e3) : 1) : null;
  };
  const blended = (m) => (m.input == null || m.output == null ? null : (BLEND.input * m.input + BLEND.output * m.output) / (BLEND.input + BLEND.output));

  // Money in a currency for the reader's locale. Without a usable currency code the amount is shown with the code in front.
  function money(v, currency, locale) {
    if (v == null || !Number.isFinite(v)) return "—";
    try {
      const small = Math.abs(v) < 1;
      return new Intl.NumberFormat(locale || undefined, { style: "currency", currency, minimumFractionDigits: small ? 2 : undefined, maximumFractionDigits: Math.abs(v) < 0.01 ? 4 : small ? 3 : 2 }).format(v);
    } catch { return currency + " " + v.toFixed(2); }
  }

  // Region to currency, for the default of the currency field (the reader can change it). Unknown regions fall back to USD.
  const REGION_CURRENCY = { US: "USD", CA: "CAD", GB: "GBP", AU: "AUD", NZ: "NZD", JP: "JPY", KR: "KRW", TW: "TWD", HK: "HKD", CN: "CNY", SG: "SGD", IN: "INR", CH: "CHF", SE: "SEK", NO: "NOK", DK: "DKK",
    PL: "PLN", CZ: "CZK", HU: "HUF", BR: "BRL", MX: "MXN", AR: "ARS", CL: "CLP", ZA: "ZAR", TR: "TRY", IL: "ILS", AE: "AED", SA: "SAR", TH: "THB", VN: "VND", ID: "IDR", MY: "MYR", PH: "PHP", UA: "UAH", RU: "RUB" };
  const EURO = ["DE", "FR", "ES", "IT", "NL", "BE", "AT", "IE", "PT", "FI", "GR", "LU", "SK", "SI", "EE", "LV", "LT", "MT", "CY", "HR"];
  function currencyForLocale(locale) {
    const region = (String(locale || "").match(/[-_]([A-Za-z]{2})\b/) || [])[1];
    if (!region) return { ja: "JPY", ko: "KRW", de: "EUR", fr: "EUR", it: "EUR", es: "EUR" }[String(locale || "").slice(0, 2).toLowerCase()] || "USD";
    const r = region.toUpperCase();
    return EURO.includes(r) ? "EUR" : REGION_CURRENCY[r] || "USD";
  }
  const COMMON_CURRENCIES = ["USD", "EUR", "GBP", "JPY", "TWD", "CNY", "KRW", "HKD", "SGD", "AUD", "CAD", "NZD", "CHF", "SEK", "NOK", "DKK", "PLN", "CZK", "BRL", "MXN", "INR", "ZAR", "TRY", "THB", "ILS", "AED"];

  // ---------- rows ----------
  const speedCell = (value, n, prelim) => (value == null ? null : { value, n: n || 0, prelim: !!prelim });

  function cloudRows(modelsJson, community) {
    const c = community || {};
    const speed = new Map((c.speed || []).map((s) => [s.model, speedCell(s.median, s.n, false)]));
    for (const s of (c.preliminary && c.preliminary.speed) || []) if (!speed.has(s.model)) speed.set(s.model, speedCell(s.median, s.n, true));
    const ratings = new Map((c.ratings || []).map((r) => [r.model, { avg: r.avg, n: r.n }]));
    return (modelsJson.models || []).map((m) => ({
      kind: "cloud", id: m.id, name: m.name, provider: m.provider, input: m.input ?? null, output: m.output ?? null, cacheRead: m.cacheRead ?? null, cacheWrite: m.cacheWrite ?? null,
      context: m.context || null, contextTokens: contextTokens(m.context), blended: blended(m), speed: speed.get(m.id) || null, rating: ratings.get(m.id) || null,
      smartness: null, priceNote: m.priceNote || null, priceSrc: m.priceSrc || null
    }));
  }

  function localRows(community) {
    const lr = (community && community.localRuns) || {};
    const make = (x, prelim) => ({
      kind: "local", id: ["local", x.model, x.paramsB ?? "", x.quant || "", x.engine, x.chip, x.memGB].join("|"),
      name: x.model + (x.paramsB ? " " + x.paramsB + "B" : "") + (x.quant ? " " + x.quant : ""), model: x.model, paramsB: x.paramsB ?? null, quant: x.quant || null,
      engine: x.engine, chip: x.chip, memGB: x.memGB, speed: speedCell(x.genTps, x.n, prelim), promptTps: prelim ? null : x.promptTps ?? null, people: x.n, prelim, smartness: null
    });
    return [...(lr.rows || []).map((x) => make(x, false)), ...(lr.preliminary || []).map((x) => make(x, true))];
  }

  // ---------- table rendering ----------
  const COLUMNS = ["type", "name", "provider", "input", "output", "cache", "blended", "context", "speed", "rating", "smartness", "elec"];
  const COL_STRING = { type: "cType", name: "cModel", provider: "cProvider", input: "cInput", output: "cOutput", cache: "cCache", blended: "cBlended", context: "cContext", speed: "cSpeed", rating: "cRating", smartness: "cSmart", elec: "cElec" };
  const NUMERIC = new Set(["input", "output", "cache", "blended", "context", "speed", "rating", "smartness", "elec"]);

  function headerHtml(lang) {
    const t = T(lang);
    return "<tr>" + COLUMNS.map((c) => {
      const hidden = c === "smartness" && !SMARTNESS.enabled ? " hidden" : "";
      return `<th scope="col" data-col="${c}" aria-sort="none"${hidden}${NUMERIC.has(c) ? ' class="num"' : ""}><button class="sort-btn" type="button" data-sort="${c}">${esc(t[COL_STRING[c]])}</button></th>`;
    }).join("") + "</tr>";
  }

  const peopleText = (t, n) => (n === 1 ? t.people1 : fill(t.peopleN, { n }));
  function speedHtml(t, s) {
    if (!s) return `<span class="muted">${t.none}</span>`;
    const v = s.prelim ? "≈" + Math.round(s.value) : s.value >= 100 ? String(Math.round(s.value)) : s.value.toFixed(1).replace(/\.0$/, "");
    return `${v}<div class="note">${esc(peopleText(t, s.n))}${s.prelim ? " · " + esc(t.prelim) : ""}</div>`;
  }

  function rowHtml(row, lang, view) {
    const t = T(lang), v = view || {};
    const none = `<span class="muted">${t.none}</span>`;
    const cells = [];
    if (row.kind === "cloud") {
      const price = (x) => (x == null ? none : usd(x));
      cells.push(esc(t.typeCloud), `<strong>${esc(row.name)}</strong>${row.priceNote ? `<div class="note">${esc(row.priceNote[lang === "zh" ? "zh" : "en"] || row.priceNote.en || "")}</div>` : ""}`,
        esc(PROVIDERS[row.provider] || row.provider), price(row.input), price(row.output), price(row.cacheRead), row.blended == null ? none : `<strong>${usd(row.blended)}</strong>`,
        esc(row.context || t.none), speedHtml(t, row.speed), row.rating ? `${esc(fill(t.ratingOf, { v: row.rating.avg }))}<div class="note">${esc(peopleText(t, row.rating.n))}</div>` : none,
        none, none);
    } else {
      const where = (ENGINES[row.engine] || row.engine) + " · " + row.chip + " · " + row.memGB + " GB";
      cells.push(esc(t.typeLocal), `<strong>${esc(row.name)}</strong>`, esc(where), none, none, none, none, none, speedHtml(t, row.speed), none, none,
        v.elec != null ? esc(v.elec) : none);
    }
    return `<tr data-kind="${row.kind}" data-id="${esc(row.id)}">` + cells.map((html, i) => {
      const col = COLUMNS[i];
      const attrs = (NUMERIC.has(col) ? ' class="num"' : "") + (col === "smartness" && !SMARTNESS.enabled ? " hidden" : "");
      return `<td data-col="${col}"${attrs}>${html}</td>`;
    }).join("") + "</tr>";
  }

  // ---------- sorting and filtering ----------
  const SORT_VALUE = {
    type: (r) => (r.kind === "cloud" ? 0 : 1), name: (r) => r.name.toLowerCase(), provider: (r) => (r.kind === "cloud" ? PROVIDERS[r.provider] || r.provider : r.engine + r.chip),
    input: (r) => r.input, output: (r) => r.output, cache: (r) => r.cacheRead, blended: (r) => r.blended, context: (r) => r.contextTokens, speed: (r) => (r.speed ? r.speed.value : null),
    rating: (r) => (r.rating ? r.rating.avg : null), smartness: (r) => r.smartness, elec: (r, view) => (view && view.elecValue ? view.elecValue(r) : null)
  };
  function sortRows(rows, key, dir, view) {
    const get = SORT_VALUE[key] || SORT_VALUE.blended, sign = dir === "desc" ? -1 : 1;
    // Rows without a value stay at the end in both directions.
    return rows.map((r, i) => [r, get(r, view), i]).sort((a, b) => {
      const x = a[1], y = b[1];
      if (x == null && y == null) return a[2] - b[2];
      if (x == null) return 1;
      if (y == null) return -1;
      return (x < y ? -1 : x > y ? 1 : 0) * sign || a[2] - b[2];
    }).map((p) => p[0]);
  }
  // Default order: cloud cheapest first, then local models by speed.
  function defaultOrder(rows) {
    const cloud = sortRows(rows.filter((r) => r.kind === "cloud"), "blended", "asc");
    const local = sortRows(rows.filter((r) => r.kind === "local"), "speed", "desc");
    return [...cloud, ...local];
  }
  // Filters: type, provider (cloud models only), a budget on the blended price (cloud models), and "my hardware" (local rows only).
  function filterRows(rows, f) {
    const x = f || {};
    const chosen = (v) => v != null && v !== "" && v !== "all";
    const hardware = chosen(x.chip) || chosen(x.mem);
    const budget = x.maxBlended != null && Number.isFinite(x.maxBlended);
    return rows.filter((r) => {
      if (chosen(x.type) && r.kind !== x.type) return false;
      if (chosen(x.provider) && !(r.kind === "cloud" && r.provider === x.provider)) return false;
      if (hardware && !(r.kind === "local" && (!chosen(x.chip) || r.chip === x.chip) && (!chosen(x.mem) || String(r.memGB) === String(x.mem)))) return false;
      if (budget && r.kind === "cloud" && (r.blended == null || r.blended > x.maxBlended)) return false;
      return true;
    });
  }

  // ---------- calculators ----------
  // Cost in USD of a month of cloud use. Tokens in millions; cachedShare 0-1 of the input read from the cache.
  function monthlyCloudUsd(row, usage) {
    if (row.input == null || row.output == null) return null;
    const cached = Math.min(Math.max(usage.cachedShare || 0, 0), 1);
    const written = Math.min(Math.max(usage.cacheWriteShare || 0, 0), 1 - cached);
    const cacheRead = row.cacheRead ?? row.input, cacheWrite = row.cacheWrite ?? row.input;
    return usage.inputM * ((1 - cached - written) * row.input + cached * cacheRead + written * cacheWrite) + usage.outputM * row.output;
  }
  // Seconds of generation (and prompt processing where the prompt speed is known) for a month of use on a local row.
  function localSeconds(row, usage) {
    if (!row.speed || !(row.speed.value > 0)) return null;
    const cached = Math.min(Math.max(usage.cachedShare || 0, 0), 1);
    let s = (usage.outputM * 1e6) / row.speed.value;
    if (row.promptTps > 0) s += (usage.inputM * (1 - cached) * 1e6) / row.promptTps;
    return s;
  }
  // Typical whole-computer power under load by chip (the same table as DevicePower in the app, docs/local-llm.md): an estimate.
  function typicalWatts(chip) {
    const m = /^Apple M[0-9]+(?: (Pro|Max|Ultra))?$/.exec(String(chip || ""));
    return m ? { Pro: 40, Max: 70, Ultra: 120 }[m[1]] || 20 : 100;
  }
  const kwhCost = (seconds, watts, price) => (seconds / 3600) * (watts / 1000) * price;
  function electricityPerMillionOutput(row, watts, price) {
    const w = watts > 0 ? watts : typicalWatts(row.chip);
    if (!row.speed || !(row.speed.value > 0) || !(price >= 0) || price === "" || price == null) return null;
    return kwhCost(1e6 / row.speed.value, w, price);
  }

  // Rows priced for a month of use, in the reader's currency. `rate` converts USD (null = none known: USD is shown for cloud models
  // when the currency is not USD). Cheapest first; rows that cannot be priced come last.
  function priceRows(rows, usage, opts) {
    const o = opts || {};
    const cur = (o.currency || "USD").toUpperCase();
    const rate = cur === "USD" ? 1 : o.rate > 0 ? o.rate : null;
    return rows.map((r) => {
      if (r.kind === "cloud") {
        const u = monthlyCloudUsd(r, usage);
        if (u == null) return { row: r, cost: null, currency: cur, seconds: r.speed && r.speed.value > 0 ? (usage.outputM * 1e6) / r.speed.value : null };
        return rate == null ? { row: r, cost: u, currency: "USD", usdFallback: true, seconds: r.speed && r.speed.value > 0 ? (usage.outputM * 1e6) / r.speed.value : null }
          : { row: r, cost: u * rate, currency: cur, seconds: r.speed && r.speed.value > 0 ? (usage.outputM * 1e6) / r.speed.value : null };
      }
      const seconds = localSeconds(r, usage);
      const ok = seconds != null && o.price > 0;
      return { row: r, cost: ok ? kwhCost(seconds, o.watts > 0 ? o.watts : typicalWatts(r.chip), o.price) : null, currency: cur, seconds, needsPrice: seconds != null && !(o.price > 0) };
    }).sort((a, b) => (a.cost == null) - (b.cost == null) || (a.cost ?? 0) - (b.cost ?? 0) || a.row.name.localeCompare(b.row.name));
  }

  function electricityScenario(x) {
    if (!(x.watts > 0) || !(x.hoursPerDay > 0) || !(x.price >= 0) || x.price === "" || x.price == null) return null;
    const days = x.days || 30;
    const kwh = (x.watts / 1000) * x.hoursPerDay * days;
    const out = { kwh, cost: kwh * x.price };
    if (x.tokensPerSecond > 0) {
      out.tokens = x.tokensPerSecond * 3600 * x.hoursPerDay * days;
      out.perMillion = out.tokens > 0 ? out.cost / (out.tokens / 1e6) : null;
    }
    return out;
  }

  // `quotapilot stats --json` to monthly millions of tokens. Local-model tokens are left out (they have no API price).
  function parseStats(text) {
    let o;
    try { o = JSON.parse(text); } catch { return null; }
    if (!o || typeof o !== "object") return null;
    const hours = Number(o.hours);
    if (!(hours > 0)) return null;
    const providers = o.providers && typeof o.providers === "object" ? Object.entries(o.providers).filter(([k]) => k !== "local").map(([, v]) => v) : o.total ? [o.total] : [];
    if (!providers.length) return null;
    const sum = (k) => providers.reduce((a, p) => a + (Number(p && p[k]) || 0), 0);
    const input = sum("input"), cacheRead = sum("cacheRead"), cacheWrite = sum("cacheWrite"), output = sum("output");   // reasoning tokens are already part of output
    const inputAll = input + cacheRead + cacheWrite;
    if (!(inputAll + output > 0)) return null;
    const scale = (30 * 24) / hours;
    return { hours, inputM: (inputAll * scale) / 1e6, outputM: (output * scale) / 1e6, cachedShare: inputAll > 0 ? cacheRead / inputAll : 0, cacheWriteShare: inputAll > 0 ? cacheWrite / inputAll : 0 };
  }

  root.AQW_MODELS = { BLEND, SMARTNESS, PROVIDERS, ENGINES, STRINGS, T, fill, esc, usd, money, contextTokens, blended, currencyForLocale, COMMON_CURRENCIES, REGION_CURRENCY, EURO,
    cloudRows, localRows, COLUMNS, headerHtml, rowHtml, speedHtml, sortRows, defaultOrder, filterRows, monthlyCloudUsd, localSeconds, kwhCost, typicalWatts, electricityPerMillionOutput, priceRows,
    electricityScenario, parseStats, peopleText };
})(typeof window !== "undefined" ? window : globalThis);
