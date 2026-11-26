# Local model usage

Last updated 2026-11-26. Status: implemented (see the checklist at the end).

QuotaPilot already labels local models used through Codex or Claude Code as provider `local` at $0. This feature counts
**all** local model usage, also when no coding agent is involved: Ollama, LM Studio, llama.cpp (`llama-server`), oMLX and Strata.

What is shown per model: requests, input tokens, output tokens, prompt and generation tokens per second where the
server reports them, active time, and an **equivalent cloud cost**: what the same tokens would cost on a reference
cloud model. That number is hypothetical (running locally costs nothing but electricity); it is always labelled as such.

Everything is off by default. Nothing is sent anywhere; no prompt or output is ever read into memory beyond the
counter fields, and never stored.

## 1. What each tool offers without a proxy (research)

Researched on 2026-11-26 in the official documentation and repositories only.

| Tool | Default port | Usage data without a proxy | Verdict |
|---|---|---|---|
| llama.cpp `llama-server` | 9931 in the current README (8080 in older builds and in the Docker examples) | `GET /metrics` Prometheus counters, only when started with `--metrics`: `llamacpp:prompt_tokens_total`, `llamacpp:prompt_seconds_total`, `llamacpp:tokens_predicted_total`, `llamacpp:tokens_predicted_seconds_total` (plus gauges). No request counter and no model label. `GET /props` / `GET /v1/models` name the model. `GET /slots` (on by default) shows only the state of the running slots, not history. | Poll `/metrics`: tokens and seconds, no request count. Needs `--metrics`. |
| Ollama | 11434 | None. `GET /api/ps` lists loaded models only. The usage fields (`prompt_eval_count`, `eval_count`, `*_duration` in nanoseconds, `prompt_eval_cached_count`) exist only in the final object of each `/api/generate` and `/api/chat` response. `server.log` (`~/.ollama/logs/server.log` on macOS, journald on Linux, `%LOCALAPPDATA%\Ollama` on Windows) is troubleshooting output and the documentation lists no token counts in it. There is no usage history endpoint. | Proxy only. |
| LM Studio | 1234 | Per response: `usage` (`prompt_tokens`, `completion_tokens`, `total_tokens`) and, on the `/api/v0` endpoints, `stats` (`tokens_per_second`, `time_to_first_token`, `generation_time`); the native `/api/v1/chat` returns `stats` with `input_tokens`, `total_output_tokens`, `tokens_per_second`, `time_to_first_token_seconds`. No history endpoint. `lms log stream` shows the exact model input and output (prompts), and the documentation does not say where logs live on disk; QuotaPilot does not read it, because it holds prompts. | Proxy only. |
| Strata (`mach10x/strata`, open-source engine for large MoE models across VRAM, RAM and SSD) | 8080 | OpenAI-compatible `POST /v1/chat/completions` and Anthropic `POST /v1/messages` (stream and non-stream). `GET /health`, `/status`, `/slots` (busy or idle only), `/props`. `GET /metrics` is a JSON page for its Monitor tab (engine, live state, last requests, hardware), not Prometheus counters; the documentation does not list its fields, and its optional API monitor keeps prompts in memory (off by default), so it is not read. The server log `strata-<model>.log` has per-request expert-tier lines in the documentation, no documented token counters. | Proxy only. Streaming usage follows the Anthropic and OpenAI shapes below. |
| oMLX (`jundot/omlx`, MLX server for Apple Silicon) | 8000 | Real usage history: `GET /admin/api/usage?range=today\|yesterday\|7d\|30d\|90d\|month[&model=]` returns `totals`, `models`, `heatmap` with `requests`, `prompt_tokens`, `completion_tokens`, `cached_tokens`, `prefill_seconds`, `generation_seconds`, `generation_tps`, `prefill_tps` and more; `GET /admin/api/stats` has session and all-time counters. Uses the main API key as a Bearer token (when the server has one). Prompts are not stored. | Poll `/admin/api/usage`. |

OpenAI-compatible responses (all four expose `/v1/chat/completions`):

- Non-streaming: the response has a `usage` object with `prompt_tokens`, `completion_tokens`, `total_tokens`, and
  optionally `prompt_tokens_details.cached_tokens`.
- Streaming (SSE): usage arrives only when the request set `stream_options: {"include_usage": true}`; it is then in a final chunk with an empty
  `choices` array. Otherwise no chunk has usage. A cancelled stream may never deliver it.
- llama.cpp adds a `timings` object: `prompt_n`, `cache_n`, `prompt_ms`, `prompt_per_second`, `predicted_n`,
  `predicted_ms`, `predicted_per_second`.
- Ollama's own API streams JSON objects (one per line); the object with `done: true` carries the counts and
  durations. Ollama's `/v1` compatibility layer lists `stream_options.include_usage` as supported.
- Anthropic-style responses (oMLX and Strata `POST /v1/messages`): non-streaming `usage.input_tokens` / `output_tokens`; streaming `message_start` carries `message.usage` (input tokens) and `message_delta` carries the final `usage.output_tokens`. Both are merged (largest value per field); `cache_read_input_tokens` counts as cached prompt. No opt-in is needed.
- oMLX documents `stream_options.include_usage` support and an Anthropic-style `/v1/messages` endpoint (usage there is
  `input_tokens` / `output_tokens`).

Sources:

- llama.cpp server: <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md> (sections `--metrics`, `/metrics`, `/slots`, "Timings and context usage")
- Ollama API usage fields: <https://github.com/ollama/ollama/blob/main/docs/api/usage.mdx>, API reference <https://github.com/ollama/ollama/blob/main/docs/api.md>
- Ollama logs: <https://github.com/ollama/ollama/blob/main/docs/troubleshooting.mdx>; port and `OLLAMA_HOST`: <https://github.com/ollama/ollama/blob/main/docs/faq.mdx>; OpenAI compatibility: <https://github.com/ollama/ollama/blob/main/docs/api/openai-compatibility.mdx>
- LM Studio REST API: <https://lmstudio.ai/docs/developer/rest/endpoints>, <https://lmstudio.ai/docs/developer/rest/chat>; `lms log stream`: <https://lmstudio.ai/docs/cli/serve/log-stream>
- oMLX: <https://github.com/jundot/omlx> (README), <https://github.com/jundot/omlx/blob/main/docs/usage-analytics.md>, <https://github.com/jundot/omlx/blob/main/docs/admin-api.md>
- Strata: <https://github.com/mach10x/strata> (README, `docs/DETAILS.md` section "Using it", `docs/INSTALL.md`)
- OpenAI streaming usage: <https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events>

Not verified (stated as such in the code and the UI): the exact JSON shape of the `models` list in oMLX's usage
response (only the metric names are documented, so the parser accepts a list or an object keyed by model id); the location
of LM Studio's log files (not documented, not used).

## 2. Data sources in QuotaPilot

| Source | Tools | Needs setup? |
|---|---|---|
| Metering proxy | any: Ollama, LM Studio, llama.cpp, oMLX, Strata, other OpenAI-compatible servers | Yes: turn on per backend, then point the client at the proxy URL |
| `/metrics` poller | llama.cpp | The server must run with `--metrics`; otherwise automatic |
| `/admin/api/usage` poller | oMLX | Automatic; an API key (Keychain) only if the oMLX server has one |
| Agent logs | Codex, Claude Code using a local model | Already existing; see the duplicate rule below |

Master switch **Local models** (off by default). When on, the pollers run; proxies run only for backends the user enabled.

### 2.1 Metering proxy

A relay on `127.0.0.1` only, one listener per configured backend (for example Ollama 11434 gives proxy 11435; Strata 8080 gives 8081). Strata and the old llama.cpp default both use port 8080; the llama.cpp poller only accepts a page with `llamacpp:` metrics, so Strata is never misread, but it shows as "answers, but /metrics is unavailable".

- **Pass-through is verbatim.** Each client connection is paired with one upstream connection and bytes are copied in both
  directions without being changed: SSE, chunked bodies, keep-alive, large uploads. Metering never sits in the forwarding
  path: a parser failure cannot change what the client receives.
- **The metering tap** reads copies of the bytes: it follows HTTP/1.1 framing (content length, chunked) to find response
  bodies, and hands only the decoded body of JSON, SSE and NDJSON responses to a field extractor. The request body is
  skipped (never buffered), so prompts are not even held in memory.
- **Extracted fields only**: `usage` (OpenAI, Anthropic, Responses API shapes), llama.cpp `timings`, Ollama final-object counts and
  durations, LM Studio `stats`, and the response's `model` id. Plus two timestamps measured by the proxy: time to the first response
  byte and time to the last.
- Text is discarded as it is parsed. Response bodies larger than 8 MB that are neither SSE nor NDJSON are not parsed.
- **Streaming without usage.** A streamed OpenAI-style request that did not ask for `include_usage` carries no counts. QuotaPilot does
  **not** guess and does **not** rewrite the request (rewriting a client's request body is not clearly safe). It counts the request
  as *unmetered* and shows "N requests without token counts" with the hint to enable `stream_options.include_usage` in the client.
  Ollama's native API and llama.cpp's non-OpenAI endpoints always include counts.
- Compressed responses (`Content-Encoding`) are forwarded untouched and counted as unmetered.
- HTTP only (no TLS) and the `Host` header is not rewritten, since bytes pass unchanged. The default upstream is loopback.
- Platforms: macOS and Linux (POSIX sockets, flock and file identity). Not on Windows: the event log needs cross-process locking and rewrite detection that Windows does not provide in the portable layer, so on Windows local model metering (the event log, pollers, the proxy and compaction) is off. Every `quotapilot local ...` command prints "local models: macOS and Linux only", nothing is written, and the local section stays empty.

### 2.2 llama.cpp poller

Every 60 s, only if the port answers within 300 ms (9931 and 8080 are tried), `GET /metrics`. Counters are diffed:
the first reading is a baseline; a counter that went down means the server restarted, and the new value counts from zero.
The model id comes from `GET /v1/models`. A router-mode server (needs `?model=`) is not polled. The event has no request count;
the stats show tokens and speeds but no request number for that line. Usage while QuotaPilot is not running is not counted.

### 2.3 oMLX poller

Every 60 s, only if port 8000 answers, `GET /admin/api/usage?range=today`; today's totals per model are diffed like counters. A
401 is shown as "needs API key". The key is stored in the login keychain (macOS app) or read from `QUOTAPILOT_OMLX_API_KEY` (CLI), never in preferences.
oMLX's own older history is not back-filled (the daily/hourly shape is undocumented); counting starts at the first poll.

### 2.4 Avoiding double counting

1. **Proxy and poller, in one process**: a backend that has its proxy enabled is not polled (the proxy sees every request that goes through it). Point every client
   at the proxy, or turn the proxy off again: direct traffic to a proxied backend is not counted.
2. **Proxy and poller, across processes**: a process that runs a proxy (the app, or `quotapilot local proxy --backend X`) holds a shared lock file
   `local-llm-proxy-<backend>.lock` in the state folder; a poller in another process that finds it held skips that backend ("metered by a proxy in another process").
   Pollers hold `local-llm-poll.lock`: the app and `quotapilot local poll` never poll together, and `local poll` refuses while the app polls. `quotapilot local status`
   only reports: it starts no proxy and takes no lock.
3. **Agent logs**: Codex and Claude Code logs already book local-model calls (provider `codex`/`claude`, model labelled local). Such an event is not booked when the
   same traffic reaches the meter: if its model id names a backend (`ollama/…`), only when that backend is metered (proxy on, or its poller running); if it names none, when any
   backend is metered. Local models off: nothing is skipped. A call to a backend that nothing meters stays in the agent logs.
4. **Events**: every event has a unique id (proxy: random; poller: backend, model, poll time). The app's reader keeps a list by id, books each id once, never books the
   merged `hour|…` events a compaction writes (their parts were booked when new), and rebuilds its list when the file was replaced.

### 2.5 The event file

Appends and compaction hold a lock file (`local-llm-events.jsonl.lock`, flock) across the whole read and rewrite, so lines appended by another process meanwhile are not lost.
The rewrite goes to a private temporary file (mode 0600 from creation) and replaces the old one by rename; readers notice a rewrite by the file's inode, not by its size,
and read in chunks with no size limit. The app compacts at start and hourly; the CLI proxy and poller compact at start. The app keeps the last 30 days in memory.

## 3. Design

- Events are appended to `local-llm-events.jsonl` in the state folder (counts, model id, timings, backend, source; nothing else).
  The app, `quotapilot local proxy` and `quotapilot stats` share the file. Events older than 35 days are dropped; events older than two
  days are compacted per hour, backend, model and source.
- Booking into the existing statistics: each event is also added as a token event of provider `local` with model `backend/model`
  (e.g. `ollama/qwen3:8b`), so the statistics window, `quotapilot stats` and the menu line include it ($0, labelled Local).
- Local-specific lines (`LocalLLMReport`): per backend and model: requests, input and output tokens, cached tokens, prompt tok/s and generation tok/s
  (sum of tokens divided by sum of seconds, over events that have timings; it is not a mean of speeds), active time (sum of measured seconds), and the
  hypothetical cloud cost.
- **Reference model for the equivalent cost** (setting, `localReferenceModel`): the default is `claude-sonnet-5-5`, a mid-tier model ($2 input / $10 output
  per million tokens in the price table). "The cheapest mid-tier model" is not stable (it changes with every price review), so a fixed, well-known mid-tier
  default is used; any priced model can be chosen. Cached prompt tokens use the model's cache-read price when it has one. If the chosen id is
  no longer in the price table, the default is used.
- Settings: `localLLM` (master switch, reference model, per-backend proxy switch, listen port, upstream host and port).

## 4. Limits

- llama.cpp without `--metrics`, Ollama and LM Studio without the proxy: not counted (no data exists).
- Streaming without `include_usage`: requests counted, tokens not.
- Tokens per second from the proxy for servers without timings are derived from measured times (time to first byte as prefill,
  the rest as generation) and are marked as proxy-measured; engine-reported timings are used when present.
- Active time is the sum of measured request seconds; overlapping requests add up, so it is not wall-clock busy time.
- Embedding and reranking requests count as requests with input tokens.
- The `/metrics` and oMLX pollers only see what happens while QuotaPilot runs.
- The oMLX parser follows documented field names but its `models` list shape is not documented; a differing shape yields totals without a model split.

## 4a. Electricity

Running locally is free of API fees but not of electricity. Enter your price and QuotaPilot shows what the measured inference time cost, next to the
hypothetical cloud cost. Nothing is computed or shown while the price is empty; there is no default price, because it differs everywhere.

| Setting | Where | Default |
|---|---|---|
| Price per kWh (shown as per kWh / 每度 / 1 kWh あたり … by language) | **Local models…** window, `quotapilot local config electricity <price> [--currency CODE]` | empty |
| Currency (ISO 4217) | same, `--currency` or `quotapilot local config currency EUR` | the system region's currency |
| Device power in W | same, `quotapilot local config power <W|auto>` | typical value for this computer, below |
| Exchange rate (units of your currency per 1 USD) | same, `quotapilot local config rate <n>` | empty; needed only to show cloud prices (USD) in your currency |

Electricity sums the measured time of every request, so requests that ran in parallel overstate the kWh.

Formulas (the same on the website calculator): `kWh = inference seconds ÷ 3600 × W ÷ 1000`; `cost = kWh × price`; `cost per 1M tokens = cost ÷ (measured tokens ÷ 1,000,000)`.
Inference seconds are the times the local servers or the proxy measured (prompt plus generation); tokens of events without a measured time are left out and the screen says
what share was measured. "Last 30 days" is the same calculation over the last 30 days of events. Numbers and currency follow the system region (the app: the interface language's formats).

Power is an **estimate**. macOS cannot read real power without administrator rights (`powermetrics` needs sudo), and QuotaPilot never asks for it. The default is a
typical whole-computer draw under sustained inference for the chip class, rounded from public measurements of Mac mini, MacBook Pro and Mac Studio under LLM load:

| Computer | Default W |
|---|---|
| Apple M-series base (M1 … M5) | 20 |
| Apple M-series Pro | 40 |
| Apple M-series Max | 70 |
| Apple M-series Ultra | 120 |
| Any other computer (Intel/AMD/other CPU, Linux, Windows; GPU not known) | 100 |

If you know your machine's real figure (a wall plug meter, or a GPU's rated power), enter it; the estimate is labelled as one wherever it is used.
`quotapilot local hardware` prints what was detected and the default. GPU cores are read from the Apple GPU's registry entry (`ioreg`), nothing is run with elevated rights.

## 4b. Sharing local runs (opt-in)

Off by default and **not** included in a default share; tick **What to share → Local model speed with this Mac's chip** (an alert shows exactly what would be sent first) or use
`quotapilot share --only localRuns` (`--json` previews). Needs **Local models** on and at least 3 timed requests per model in the share window.

Per model and engine the report (`type: "localrun"`) holds: public model name (family and version, no size or quantization), parameter size, quantization, engine (the app sends `ollama`, `lmstudio`,
`llamacpp`, `omlx`, `strata` or `other`; the collector also accepts `mlx` and `vllm`), engine version (`major.minor`, or `b4567` for llama.cpp; Ollama `/api/version` and llama.cpp `/props` are read on loopback with a 0.5 s timeout, other engines
report none), chip (`Apple M4 Max`; others only the vendor), memory tier (rounded up to 8/16/24/32/48/64/96/128/192/256 GB), GPU core bucket (10/20/40/80), OS family and major, median generation
and prompt tokens per second over the events, and the sample count. The name check (`LocalModelName`) accepts only known open-weight families, sizes, quantizations and a list of descriptive words;
anything else leaves the whole model out. The collector applies the same grammar to the shared id (`isLocalModelId`; a fixture list, `collector/test/local-model-fixture.json`, is tested by both Swift and JS), so free text after a family name is refused. Engines whose upstream is not this computer are skipped. Detection: macOS `sysctl machdep.cpu.brand_string`, `ProcessInfo.physicalMemory` and one `ioreg`
read for GPU cores; Linux `/proc/cpuinfo`; Windows the processor name from the environment (no GPU cores or engine versions there). Not editable before sending: the preview is the contract; decline
by leaving the choice off.

Collector: `collector/schema.js` allows the same fixed lists and refuses a report without model, engine, chip, memory tier, OS, sample count and a speed. Aggregation (`site/scripts/aggregate.mjs`)
re-checks and rejects implausible claims (generation speed above `min(5000, 12000 ÷ billions of parameters)` tok/s, weights larger than 1.3 × the memory tier, fewer than 3 samples), keeps one report
per person, group and day, and publishes `localRuns.rows` (3 or more established people; median and quartiles) and `localRuns.preliminary` (1-2 people; generation speed rounded to 5 tok/s, people count only) in `community.json`.

## 5. Test plan

Fixtures and a fake local HTTP server on real loopback sockets; none of the five tools is needed (`Tests/UsageCoreTests/LocalLLMTests.swift`).

- Parsing: OpenAI JSON, SSE with and without the final usage chunk, Anthropic SSE (also through the proxy), Responses API, Ollama JSON and NDJSON, llama.cpp `timings`,
  LM Studio `stats`, embeddings, Prometheus text (labels, comments, NaN), oMLX usage JSON (list, object and totals-only shapes).
- Framing: chunked one byte at a time, request bodies, garbage, HEAD with Content-Length followed by a POST on the same connection.
- Proxy: byte-for-byte equality for content-length, chunked, SSE (also delivered one byte at a time) and NDJSON; keep-alive with several requests; non-model paths ignored;
  unmetered stream; engine and proxy-derived timings; 502 when the upstream is down; refusal of privileged ports; stop() frees the port at once (restart on the same port, also through the service).
- Pollers: counter diff, restart (counter reset), first-reading baseline, off when the feature is off, 401 and missing `/metrics`, oMLX key header; skipped for a backend proxied by another
  process, refused while another process polls; `status` probe starts nothing and takes no lock.
- Event file: append, tail, compaction (merge, retention, mode 0600), reader surviving a compaction by another process without duplicates or double booking, rewrite detected
  although the file is not smaller, no appends lost while compacting (four writer threads and a compactor), chunked reads across line boundaries, 30-day trim.
- Dedupe: same event id once in the store and ledger, agent-log rule per backend, proxy/poller rule, process locks (exclusive and shared).
- Cost on the reference model including cache read price and fallback to the default; settings round trip and validation.
- Localization completeness for all ten languages. Linux and Windows builds: the socket code is guarded with `#if canImport(Darwin/Glibc/Musl)` (Glibc enum constants are converted
  with `Int32(...)`) and the non-POSIX proxy stub mirrors the real class's properties; neither platform could be built in the development environment.

## 6. Checklist

- [x] research and this document
- [x] core: events, parsers, stats, proxy, pollers
- [x] app: Local models window, statistics window lines, menu line
- [x] CLI: `quotapilot local status|stats|poll|proxy|config`, `quotapilot stats` includes local
- [x] tests, docs, changelog
- [x] sharing: `localrun` reports, collector allow-list, aggregation, preview, PRIVACY.md
- [x] electricity: price, currency, power, exchange rate; app lines, `quotapilot local stats|hardware|config`
