# Local model usage

Last updated 2026-11-26. Status: design, implemented in the same change series (see the checklist at the end).

QuotaPilot already labels local models used through Codex or Claude Code as provider `local` at $0. This feature counts
**all** local model usage, also when no coding agent is involved: Ollama, LM Studio, llama.cpp (`llama-server`) and oMLX.

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
- oMLX documents `stream_options.include_usage` support and an Anthropic-style `/v1/messages` endpoint (usage there is
  `input_tokens` / `output_tokens`).

Sources:

- llama.cpp server: <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md> (sections `--metrics`, `/metrics`, `/slots`, "Timings and context usage")
- Ollama API usage fields: <https://github.com/ollama/ollama/blob/main/docs/api/usage.mdx>, API reference <https://github.com/ollama/ollama/blob/main/docs/api.md>
- Ollama logs: <https://github.com/ollama/ollama/blob/main/docs/troubleshooting.mdx>; port and `OLLAMA_HOST`: <https://github.com/ollama/ollama/blob/main/docs/faq.mdx>; OpenAI compatibility: <https://github.com/ollama/ollama/blob/main/docs/api/openai-compatibility.mdx>
- LM Studio REST API: <https://lmstudio.ai/docs/developer/rest/endpoints>, <https://lmstudio.ai/docs/developer/rest/chat>; `lms log stream`: <https://lmstudio.ai/docs/cli/serve/log-stream>
- oMLX: <https://github.com/jundot/omlx> (README), <https://github.com/jundot/omlx/blob/main/docs/usage-analytics.md>, <https://github.com/jundot/omlx/blob/main/docs/admin-api.md>
- OpenAI streaming usage: <https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events>

Not verified (stated as such in the code and the UI): the exact JSON shape of the `models` list in oMLX's usage
response (only the metric names are documented, so the parser accepts a list or an object keyed by model id); the location
of LM Studio's log files (not documented, not used).

## 2. Data sources in QuotaPilot

| Source | Tools | Needs setup? |
|---|---|---|
| Metering proxy | any: Ollama, LM Studio, llama.cpp, oMLX, other OpenAI-compatible servers | Yes: turn on per backend, then point the client at the proxy URL |
| `/metrics` poller | llama.cpp | The server must run with `--metrics`; otherwise automatic |
| `/admin/api/usage` poller | oMLX | Automatic; an API key (Keychain) only if the oMLX server has one |
| Agent logs | Codex, Claude Code using a local model | Already existing; see the duplicate rule below |

Master switch **Local models** (off by default). When on, the pollers run; proxies run only for backends the user enabled.

### 2.1 Metering proxy

A relay on `127.0.0.1` only, one listener per configured backend (for example Ollama 11434 gives proxy 11435).

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
- Platforms: macOS and Linux (POSIX sockets). Not on Windows (no sockets in the portable layer); `quotapilot local proxy` says so.

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

1. **Proxy and poller**: a backend that has its proxy enabled is not polled (the proxy sees every request that goes through it). Point every client
   at the proxy, or turn the proxy off again: direct traffic to a proxied backend is not counted.
2. **Agent logs**: Codex and Claude Code logs already book local-model calls (provider `codex`/`claude`, model labelled local). While Local models is on,
   those events are not added to the totals, because the same calls reach the meter when the agent talks to a metered backend. Turn the switch off to
   count them from the logs. A call to a local server that is not metered by any source is then missed: enable the proxy for it.
3. **Events**: every event has a unique id (proxy: random; poller: backend, model, poll time), so replaying the event file adds nothing twice.

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

## 5. Test plan

Fixtures and a fake local HTTP server; none of the four tools is needed.

- Parsing: OpenAI JSON, SSE with and without the final usage chunk, Anthropic SSE, Responses API, Ollama JSON and NDJSON, llama.cpp `timings`, LM Studio `stats`,
  Prometheus text (labels, comments, NaN), oMLX usage JSON (list and object shapes).
- Proxy: byte-for-byte equality for a content-length response, chunked response and SSE (incl. one byte at a time delivery), keep-alive with two
  requests, metered events from each; unmetered stream; refusal to listen on non-loopback.
- Pollers: counter diff, restart (counter reset), first-reading baseline, skipped when proxied.
- Dedupe: replayed event file, agent-log rule, proxy/poller rule.
- Cost on the reference model including cache read price and fallback to the default.
- Localization completeness for all ten languages; Linux and Windows builds keep compiling (socket code is guarded).

## 6. Checklist

- [x] research and this document
- [ ] core: events, parsers, stats, proxy, pollers
- [ ] app: Local models window, statistics window lines, menu line
- [ ] CLI: `quotapilot local status|proxy|stats`, `quotapilot stats` includes local
- [ ] tests, docs, changelog
