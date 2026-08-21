# Retail sentiment (ops + architecture)

What retail investors are saying about the stocks a user holds and watches, plus
a market-wide view. Scores are free; the evidence behind them is Pro.

Extends the existing `Insights/` module rather than replacing it. `HermesSyncJob`
keeps pulling the raw firehose every 15 minutes; a separate daily job turns those
posts into materialized aggregates.

## The one switch that matters

```bash
DEEPAPI_SOCIAL_SCRAPING_ENABLED=true
```

With this **off**, the DeepAPI provider declares no sentiment sources at all and
the chain falls through to direct APIs. Before this feature it silently scored
web-search snippets instead — press sentiment wearing a retail label, which
looks healthy on every dashboard while measuring the wrong population.

Set `true` in `norviq-infra/apps/api/values-{staging,production}.yaml`. Defaults
to `false` locally because scrape runs cost orders of magnitude more than a web
search and will drain a small balance in one sync.

## Data model

| Table | Purpose | Retention |
|-------|---------|-----------|
| `ticker_sentiment_posts` | Raw posts, one row per post. Gained a `source` column. | 90d (`SENTIMENT_POST_RETENTION_DAYS`) |
| `symbol_sentiment_daily` | One materialized aggregate per symbol per day. The read path. | 730d (`SENTIMENT_DAILY_RETENTION_DAYS`) |
| `sentiment_universe_symbols` | Which symbols the job is responsible for, and at what tier. | — |
| `sentiment_snapshots` | Pre-existing topic/overall snapshots. Untouched. | — |

`symbol_sentiment_daily.score` is **nullable, and null is load-bearing**: it
means no chatter was measured, which is not the same as a balanced crowd. Every
client renders absence distinctly and must never substitute a zero. `postCount`
still counts unscoreable posts — they are chatter even when they carry no
sentiment term.

Nothing pruned any of these tables before this work, in a codebase that retires
scenario runs, assistant transcripts and expense imports on a timer. Post text
is unbounded `TEXT` and the universe expansion multiplies daily row count by
roughly forty, so `SentimentRetentionJob` is load-bearing, not tidying.

## The symbol universe

Three tiers, spent in priority order. `SentimentUniverseResolver` rebuilds Tier A
every run from live holdings and watchlists, so a symbol added this morning is
covered tonight.

| Tier | Membership | Sources | LLM themes | Limit |
|------|-----------|---------|-----------|-------|
| `user` | Union of all users' holdings + non-archived watchlists, plus `HERMES_TRACKED_TICKERS` pins | all | yes | `SENTIMENT_USER_TIER_LIMIT` (500) |
| `sp500` | Index membership | cheap only | no | list size |
| `trending` | Surfaced by the firehose, held by nobody | cheap only | no | `SENTIMENT_TRENDING_TIER_LIMIT` (50) |

Before this, the universe was a global **top-25 by holder count**, so a user's
long-tail holdings were never ingested at all.

### Tier B is configured, not hardcoded

Set either:

```bash
SENTIMENT_SP500_SYMBOLS=AAPL,MSFT,...   # explicit, wins
FMP_API_KEY=...                          # fetched from FMP's constituent endpoint
```

Neither set means Tier B stays empty and the universe is user symbols only —
coverage degrades, nothing breaks. A constituent list baked into the binary
would be wrong within months, and wrong *silently*: a missing symbol is
indistinguishable from a quiet one.

## Provider chain

```
Hermes (self-hosted, tailnet) -> DeepAPI -> Direct APIs -> Disabled
```

| Provider | Sources | Notes |
|----------|---------|-------|
| Hermes | X | Self-hosted VPS, free at the margin |
| DeepAPI | X, Reddit, StockTwits, Investing.com, Seeking Alpha | Only path to the last two; gated on `DEEPAPI_SOCIAL_SCRAPING_ENABLED` |
| Direct | StockTwits, Reddit, news | Free or already paid for. No Investing.com / Seeking Alpha — they have no free API |

The direct link exists so an exhausted DeepAPI balance **thins** coverage instead
of stopping sentiment. StockTwits and Finnhub news need no extra config; Reddit
needs a script app (`REDDIT_CLIENT_ID` / `REDDIT_CLIENT_SECRET`).

StockTwits users self-tag Bullish/Bearish. That is a stated stance from the
author, so it is trusted over the lexicon — but at 0.8 confidence, not 1.0, since
it is still one data point.

### Credit exhaustion

Previously `insufficient_credits` was flattened into a generic `Abort` — fine as
failover, useless as a signal. A dry account and a network blip produced
identical logs, and `FallbackInsightsProvider.health` aggregates with `any`, so
the chain reported green while the paid tier had been skipped for days.

Now it throws a typed `InsightsProviderError.creditsExhausted`, which:

1. still falls through to the next provider, and
2. puts that provider in cooldown for `PROVIDER_CREDIT_COOLDOWN_SECONDS` (6h).

Without the cooldown, a universe sweep rediscovers the dry balance on every one
of its hundreds of calls, each costing a request that cannot succeed. A later
success clears it early.

The registry is in-process, not Redis-backed: Redis is optional here and disabled
outright under `.testing`, and a cooldown that silently does nothing in tests is
worse than one with a known limit. The limit is one wasted call per replica per
window.

## Scoring: hybrid

**Stage 1 — `SentimentClassifier`, every post.** Pure, synchronous, no I/O.

This replaced three divergent lexicons inside `DeepAPIInsightsProvider` (one for
web snippets, one for tweets, one for Reddit) that disagreed on thresholds, on
vocabulary, and on what a score of zero meant. Three behaviours changed
deliberately:

- **Word-boundary matching.** The old scorers used `contains`, so `"up"` fired on
  *supply*, *disruption* and *upset*, and `"down"` fired on *download*. Only
  phrases and emoji are substring-matched now.
- **Negation.** "not bullish" previously scored bullish.
- **Confidence measures evidence.** The old value was `min(1, abs(score) * 2)` —
  a restatement of the score wearing a different name.

Scores saturate via `sum / (abs(sum) + 2)` rather than running away, and
aggregation is confidence-weighted so one ambiguous word does not move a symbol
as far as five unambiguous ones.

**Stage 2 — `SentimentThemeService`, Tier A only.** One OpenAI call per symbol
over the day's top ~40 posts, `response_format: json_object`. Follows the split
already used by `DefaultAIInsightsService`: the server computes every number, the
model only names and narrates. A theme failure leaves `themes` null and the row
still ships its score.

Skipped entirely when `app.openAIChatClient` is `DisabledOpenAIChatClient`.

## Jobs

| Job | Cadence | Guard |
|-----|---------|-------|
| `HermesSyncJob` | 900s (unchanged) | provider enabled |
| `SentimentAggregationJob` | hourly tick, runs once per UTC day | provider enabled, not `.testing` |
| `SentimentRetentionJob` | daily | not `.testing` |

The daily cadence is built on an hourly tick that no-ops unless
`SENTIMENT_AGGREGATION_HOUR_UTC` has passed and today's date has not been
completed. A naive 24-hour interval would let a pod that restarts at 04:00 every
day never reach its first tick.

Both new jobs skip scheduling under `.testing`. A test app migrates and reverts
its schema inside one process; a timer that outlives a suite and then deletes
from tables that no longer exist turns an unrelated test into a crash. Both
expose `runOnce(_ app:)`.

`HermesSyncJob` and `SentimentAggregationJob` stay separate on purpose — merging
them would tie the cheap 15-minute pull to the expensive once-a-day LLM pass, and
either failing would take the other down.

## API

All under `/v1/insights`, scope `insights:read`, rate limited 60/60s by the
existing group.

| Route | Gating |
|-------|--------|
| `GET /sentiment/symbols?symbols=AAPL,MSFT` | free, ≤100 symbols |
| `GET /sentiment/portfolio?portfolioListId=` | free |
| `GET /sentiment/watchlist?watchlistListId=` | free |
| `GET /sentiment/trending?limit=20` | free |
| `GET /sentiment/history/{symbol}?limit=30` | **Pro** |
| `GET /tickers/{symbol}/sentiment` (pre-existing) | **Pro** |
| `POST /sentiment/sync` | admin (`INSIGHTS_ADMIN_EMAILS`) |
| `POST /sentiment/seed-index` | admin |

The free/Pro line is **aggregate vs evidence**. Free endpoints return score,
label, counts, delta and coverage — never post text or LLM themes. The score is
what makes someone open the app; the reasoning behind it is the paid product.

Reads never touch a provider. Everything is served from Postgres, so a scraping
outage costs freshness, never latency.

### Roll-up weighting

Portfolio is **value-weighted** (`shares × live quote`, falling back to cost
basis when a quote is missing). Sentiment on a 40% position and a 0.5% position
are not equally relevant to the owner.

Watchlist is **equal-weighted** — there are no position sizes to weight by, and
inventing one would be a lie.

`coverage` is not cosmetic. The weighted score is computed over only the
positions that carry a reading, so a score drawn from 2 of 10 holdings would
otherwise read as portfolio-wide. Every client renders coverage alongside the
score and flags it below 50%.

### Trending ranks by `volumeZ`, not post count

Chatter volume relative to each symbol's *own* trailing baseline. Ranking by raw
count would return the same megacaps every day — AAPL always out-posts a small
cap. `volumeZ` is null below 5 days of history: with two data points the standard
deviation is noise, and a fabricated z-score would rank a brand-new symbol
straight to the top.

## Clients

**Web** (`norviq-web`): badges on holding and watchlist rows via a batch fetch at
the existing `loadPortfolioMarketEnrichment` seam, roll-up on the portfolio hero
and watchlist, daily reading + themes + 30-day chart on the stock detail tab,
and `/markets/sentiment`.

**iOS** (`norviq-ios`): `RetailSentimentBadge` on rows, `PortfolioSentimentCard`,
`MarketSentimentScreen` under Markets, and the detail tab extended with a daily
card and a Swift Charts history.

Two client-side rules worth keeping:

- Sentiment is a **daily** aggregate. Keep it off the 20s quote-refresh timer —
  fetch once per load and on pull-to-refresh.
- The history chart pins its Y axis to the full −100…100 range. Auto-scaling
  turns a week of near-neutral noise into a dramatic-looking swing, which is
  exactly the misreading it must not invite.

## Ops

Force a run without waiting for the scheduler:

```bash
curl -X POST https://api.norviq.org/v1/insights/sentiment/sync \
  -H "Authorization: Bearer $ADMIN_JWT"
```

Returns counts for symbols considered/ingested/failed, posts fetched/inserted,
rows upserted, and themes generated/skipped.

Seed or refresh Tier B:

```bash
curl -X POST https://api.norviq.org/v1/insights/sentiment/seed-index \
  -H "Authorization: Bearer $ADMIN_JWT"
```

### Cost

The per-symbol LLM call is the only per-symbol AI spend, capped by
`SENTIMENT_MAX_THEME_SYMBOLS` (150) on top of the existing `AIDailyCap`. Tiers B
and C never reach the LLM. Scrape spend is bounded per call by
`DEEPAPI_MAX_COST_USD` and per run by the tier limits.

### Diagnosing a quiet feature

1. `postCount` 0 everywhere → check `DEEPAPI_SOCIAL_SCRAPING_ENABLED`.
2. Scores present but only from `news` → DeepAPI is likely in credit cooldown;
   grep logs for `is out of credit`.
3. A specific symbol has no reading → check it is in
   `sentiment_universe_symbols`; only Tier A is rebuilt automatically.
4. Trending empty but symbols have scores → `volumeZ` needs 5 days of history per
   symbol before it is populated.

## Not advice

Sentiment describes what retail investors are posting, not whether they are
right. Every surface carries a disclaimer, and the LLM prompt forbids
recommendations, price targets and predictions.
