# Hermes finance API — deploy bundle

Canonical copy of the Hermes finance API server that runs on the VPS
(`78.46.192.73`, systemd unit `finance-api.service`), plus a one-shot deploy
script. Design and roadmap: `docs/post-mvp-financial-platform.md`.

## What the hardened server adds over the original

- `FINANCE_API_TOKEN` bearer auth on every route except `/healthz` and `/`
  (constant-time compare).
- `GET /finance/ticker/{symbol}/posts?days=N&limit=M` backed by a new
  `ticker_posts` SQLite table (created on first use) for notable-account
  X posts per symbol.
- Fixed timestamp format (`+00:00`, previously the invalid `+00:00Z`). The
  backend parses both, so deploy order does not matter.

## Deploy

1. One-time on the VPS: `tailscale up --hostname=hermes-vps`, authenticate via
   the printed URL.
2. From this directory: `./deploy-hermes-api.sh`
   - uploads the server, binds it to the tailnet IP (no more localhost/public),
   - generates a bearer token, installs it via systemd override, restarts,
   - verifies 401 without token / 200 with token,
   - prints the `HERMES_BASE_URL` + `HERMES_API_TOKEN` lines for the backend env.
3. One-time on the backend host (168.119.156.43):
   `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up --hostname=stockplan-backend`
   then add the printed env lines to the backend `.env.production` and restart the app.
4. Verify container → tailnet routing:
   `docker exec <app-container> curl -s http://<tailnet-ip>:8780/healthz`
   If blocked: `iptables -A FORWARD -i docker0 -o tailscale0 -j ACCEPT`
   (plus the ESTABLISHED,RELATED reverse rule).

## Ticker + topic ingest (`ticker_sentiment_scraper.py`)

Built. Uses the xAI Agent Tools API (no HTML scraping) — see
`INGEST-SOURCES.md` for the source spec.

- `--mode tickers`: notable X posts per symbol → `ticker_posts` (tweet id as
  dedupe key end-to-end). Timer: every 45 min.
- `--mode topics`: X + news per financial topic → real `fin_event` rows.
  Timer: daily 06:20 UTC.
- `--purge-source manual --yes`: deletes the junk-classified legacy rows.
- Config: `scraper_config.json` (symbols, curated `notable_handles` ≤10,
  caps, model). Keep symbols in sync with backend `HERMES_TRACKED_TICKERS`.
- Requires `XAI_API_KEY` in `/root/.hermes/.env` on the VPS (present; needs
  xAI API credits to actually run).
- Deploy: `./deploy-ticker-scraper.sh` (uploads, installs timers, runs a live
  verification pass).
- Both modes now exit non-zero when *every* symbol/topic fails, so systemd
  marks the timer failed instead of reporting success on an empty run.

## Freeze post-mortem (2026-07-29)

`ticker_posts` stopped growing after 2026-07-28 and prod's `hermes_sync`
logged `ticker_posts=0` on every 15-minute tick. Two independent causes:

1. **The systemd timers were not installed on the VPS.** `finance-api.service`
   survived the rebuild; `hermes-ticker-scraper.timer` and
   `hermes-topic-ingest.timer` did not, so the ingest only ran when someone
   ran it by hand. Re-run `./deploy-ticker-scraper.sh` after any VPS rebuild,
   and check `systemctl list-timers 'hermes-*'` as part of the rebuild
   checklist.
2. **`XAI_API_KEY` is rejected by xAI** — `HTTP 400 {"code":"invalid-argument",
   "error":"Incorrect API key provided"}`. Not missing, invalid. The key needs
   rotating at <https://console.x.ai>; timers alone do not fix this.

Cause 2 hid behind the old exit-code behaviour: every symbol failed, the
process still exited 0, and the timer reported success. Hence the change above.

Diagnosing this from prod: `hermes_sync` now logs `ticker_posts_fetched` and
`ticker_posts_newest` alongside `ticker_posts`. `ticker_posts=0` with
`ticker_posts_fetched>0` is a healthy steady state (nothing new upstream);
`ticker_posts_fetched=0` means the feed itself is dead.

## Data-quality warning (as of 2026-07-03)

The current `fin_event` store (3,114 events) is junk-classified content — anime
and movie page titles labeled as Retirement/Housing/Crypto — because the ingest
consumed unrelated markdown. Before trusting `/finance/summary` numbers, point
the ingest at real financial sources and re-seed the SQLite store.
