# Portfolio-scoped multi-source news

## Personalization

News is always scoped to symbols the user **holds** (`stocks`) or **actively watches** (`watchlist_items` with status ≠ `archived`).

| Path | Behavior |
|------|----------|
| `POST /v1/news/sync` | Per user: fetch only their tracked symbols → upsert `news_items` |
| `GET /v1/news/feed` | Per user: list `news_items` for tracked symbols only |
| `NewsSyncJob` (background) | Global union of all tracked symbols → fetch once → fan out to users who track each symbol |
| `GET /v1/market/news?symbol=` | Shared `market_news_archive` (symbol-scoped, TTL) |

Example: user A holds AMD+NVDA and user B holds HIMS+OSCR. A never receives HIMS/OSCR rows; B never receives AMD/NVDA rows.

## Providers

Configured via `NEWS_PROVIDERS` (comma-separated). Default: `finnhub`.

| Value | Requirements | Notes |
|-------|--------------|--------|
| `finnhub` | `FINNHUB_API_KEY` | Company news API (primary) |
| `rss` / `yahoo` / `yahoo_rss` | `NEWS_RSS_URL_TEMPLATE` with `{symbol}` | Allowed RSS/Atom only — **not** HTML scrapers |

Optional RSS env:

| Variable | Default | Purpose |
|----------|---------|---------|
| `NEWS_RSS_URL_TEMPLATE` | _(empty = disabled)_ | e.g. `https://feeds.finance.yahoo.com/rss/2.0/headline?s={symbol}&region=US&lang=en-US` |
| `NEWS_RSS_SOURCE_NAME` | `rss` | Label stored in `source` |
| `NEWS_RSS_MAX_ARTICLES_PER_SYMBOL` | `15` | Cap per symbol per sync |

Multiple providers are merged by `CompositeNewsProvider` (soft-fail per child, dedupe by URL).

## Background job

| Variable | Default | Purpose |
|----------|---------|---------|
| `NEWS_SYNC_JOB_ENABLED` | `true` | Set `false` to skip scheduling |
| `NEWS_SYNC_INTERVAL_SECONDS` | `900` | Tick interval (min 60) |
| `NEWS_SYNC_MAX_SYMBOLS` | `100` | Cap global symbol set (ranked by holder count) |

## Explicit non-goals

- **No HTML scraping** of Seeking Alpha or Investing.com (ToS; see `MacroEnrichmentStubs.swift`).
- Full article body storage is out of scope — headline, summary, source, URL only.
- Seeking Alpha / Investing.com articles may still appear when a licensed aggregator (e.g. Finnhub) returns them with that publisher as `source`.

## Client surfaces (unchanged)

- iOS: portfolio news + stock detail news tab
- Web: `/portfolio/news` + stock news tab
- Pull-to-refresh should call `POST /v1/news/sync`; background job keeps feeds warm without app open
