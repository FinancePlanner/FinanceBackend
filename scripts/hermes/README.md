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
- Requires `XAI_API_KEY` in `/root/.hermes/.env` on the VPS (present, but
  currently **rejected** by xAI — see the post-mortem below).
- `./deploy-ticker-scraper.sh` installs systemd timers. **Superseded — do not
  run it against the live VPS**; see "This script is no longer the live ingest
  path" below.
- Both modes exit non-zero when *every* symbol/topic fails, so a scheduler
  reports the failure instead of a successful empty run.

## This script is no longer the live ingest path

As of 2026-07-29 retrieval moved into **Hermes agent cron jobs**, not systemd:

| job | schedule | role |
| --- | --- | --- |
| `hermes-ticker-sentiment` | `30 13,17,21 * * 1-5` | Stage A — retrieves raw X posts via the `x_search` tool |
| `hermes-topic-sentiment` | `0 6 * * *` | Stage A for topics |
| `hermes-sentiment-score-ingest` | `45 6,13,17,21 * * *` | Stage B — scores Stage A output on free NVIDIA NIM (`no_agent`) |

The old every-45-minutes `hermes-ticker-sentiment` interval job is **disabled on
purpose** — it re-scraped a 7-day window every 45 minutes, ~92% redundant work,
and was the bulk of the xAI bill.

**Do not run `deploy-ticker-scraper.sh` on the live VPS.** It installs systemd
timers at the old 45-minute cadence, which double-schedules the ingest alongside
the Hermes cron jobs and undoes that cost reduction. The script and its
`--mode tickers` / `--mode topics` paths are kept for local runs, backfills, and
`--purge-source`. Check `hermes cron` / `cron/jobs.json` before assuming
anything here is what production runs.

## Freeze post-mortem (2026-07-30)

`ticker_posts` stopped growing after 2026-07-28 and prod's `hermes_sync` logged
`ticker_posts=0` on every 15-minute tick.

**Cause: `XAI_API_KEY` is rejected by xAI** — `invalid-argument: Incorrect API
key provided`. Not missing, invalid. Confirmed on the live path, not just this
script: `logs/agent.log` shows the Stage A `x_search` tool returning that error
on every call. The key needs rotating at <https://console.x.ai>.

(Note for anyone reading the earlier note about a `403 personal-team-blocked:
spending-limit` on 2026-07-29 — that is a *different* failure. Today's is a
rejected key. Topping up credits alone will not fix a key the API refuses.)

This hid behind the old exit-code behaviour: every symbol failed, the process
still exited 0, so any scheduler reported success. Hence the change above.

Diagnosing this from prod: `hermes_sync` now logs `ticker_posts_fetched` and
`ticker_posts_newest` alongside `ticker_posts`. `ticker_posts=0` with
`ticker_posts_fetched>0` is a healthy steady state (nothing new upstream);
`ticker_posts_fetched=0` means the feed itself is dead.

## Data-quality warning (as of 2026-07-03)

The current `fin_event` store (3,114 events) is junk-classified content — anime
and movie page titles labeled as Retirement/Housing/Crypto — because the ingest
consumed unrelated markdown. Before trusting `/finance/summary` numbers, point
the ingest at real financial sources and re-seed the SQLite store.
