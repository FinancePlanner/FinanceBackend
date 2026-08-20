# Market data providers and the FMP plan tier

How Norviq prices instruments, why non-US symbols do not resolve today, and exactly what to
change if the FMP subscription is ever upgraded.

Written 2026-08-20. Prices verified against FMP's pricing page on that date — re-check before
acting on them.

## How a quote is produced

`MarketDataService.quote(symbol:on:)` asks the **primary** provider first, then falls back.

The primary is chosen at boot by `MarketDataProviderKind.select` (`MarketDataProviderSelection.swift`):

| `MARKET_PROVIDER` | Requires | Result |
|---|---|---|
| `finnhub` | `FINNHUB_API_KEY` | Finnhub |
| `ibkr` | `IBKR_API_BASE_URL` | IBKR |
| unset | whichever key exists, Finnhub first | Finnhub / IBKR / disabled |

Production currently runs `MARKET_PROVIDER=finnhub` with a valid key.

**Both "no provider" and "symbol not covered" look identical from the outside**:
`DisabledMarketDataProvider.quote` returns `price: 0` with every other field nil, and Finnhub
answers an uncovered symbol with `c:0` rather than an error. `isEmptyQuote` treats either as a
miss. To tell them apart, quote a symbol you know is covered, e.g. `AAPL` — a real price means
the provider is healthy and the original symbol is simply outside its coverage.

On a miss, `fmpFallbackQuote` tries FMP. If that also misses:

- `GET /v1/market/quote/:symbol` returns **404** (`MarketQuoteUnavailableError`).
- `GET /v1/market/details` still returns **200** with a zeroed body — it backs a whole screen
  and must not fail wholesale.
- **Nothing is written to `QuoteCache` or Redis.** Caching a zero turns a coverage gap or a
  transient outage into a `0.00` that outlives its cause. Do not "optimise" this away.

## Why VWCE does not resolve

Finnhub's plan does not cover Euronext Amsterdam. FMP *could*, but the fallback is gated by
`validateFMPSymbolAccess`, and on the free tier only a hardcoded 87-symbol US large-cap
allowlist (`FMPSymbolPlanAccess.freeTierSupportedSymbols`) is licensed. So the fallback is
skipped, logged as `market.quote fmp_fallback_skipped ... reason=tier`, and the caller gets a
404 rather than a fabricated price.

That is the intended behaviour while on the free plan. It is not a bug.

## What the tier controls

`FMP_SYMBOL_ACCESS_TIER` → `FMPAccessTier` (`MarketDataService.swift`). Three effects:

| | `free` | `starter` | `premium` |
|---|---|---|---|
| Symbols | 87-symbol allowlist | all | all |
| Price history range | 1 month | 1 year | 5 years |
| Analyst estimates | annual only | annual only | annual + quarterly |

## ⚠️ The enum does not match FMP's real plans

**Read this before buying anything.**

FMP splits coverage three ways — US only, US+UK+Canada, and full global. Our enum only knows
"restricted" (`free`) versus "everything" (`starter`, `premium`, both `allowsAllSymbols = true`).

FMP plans as of 2026-08-20:

| Plan | Price | Coverage |
|---|---|---|
| Basic | free | US exchanges only |
| Starter | $19/mo | US, or US+UK+Canada by endpoint |
| Premium | $49/mo | US+UK+Canada on most endpoints |
| **Ultimate** | **$99/mo** | **Full global** |

**Only Ultimate covers Euronext Amsterdam / Xetra, so only Ultimate makes VWCE resolve.**

The trap: buying **Premium ($49)** and setting `FMP_SYMBOL_ACCESS_TIER=premium` makes the code
believe every symbol is licensed. VWCE requests would then pass the gate and fail at FMP —
trading a clean 404 for a wasted API call and a slower failure. The gate exists precisely to
avoid that.

## If you upgrade the plan

1. **Buy Ultimate** ($99/mo at time of writing; annual billing advertised up to 34% off).
   Starter and Premium do **not** unlock non-US symbols.

2. **Fix the enum before or with the config change.** Add a case that reflects FMP's actual
   tiers rather than reusing `premium` to mean "global". Suggested shape:

   ```swift
   enum FMPAccessTier: String {
       case free       // Basic  — US only, and only our 87-symbol allowlist
       case starter    // US + UK + Canada
       case premium    // US + UK + Canada, longer history, quarterly estimates
       case ultimate   // full global coverage
   }
   ```

   `allowsAllSymbols` should be `true` only for `.ultimate`. `.starter` and `.premium` need a
   coverage check that accepts US/UK/Canada listings instead of the free allowlist — without it,
   setting either one re-creates the trap above. `FMPAccessTier.fromEnvironment()` already
   defaults to `.free` on an unrecognised value, so an unknown string fails safe.

3. **Update the SealedSecret.** `FMP_SYMBOL_ACCESS_TIER` lives in the `api-env`
   SealedSecret (bitnami), not in plain config:
   `<infra-repo>/secrets/norviq/production/api-env.yaml`, namespace `norviq`.
   Re-encrypt just that key with `kubeseal`, commit, let ArgoCD apply, and restart the api
   deployment. Do the same for `secrets/norviq/staging/` if you want staging to match.

4. **Verify against a real non-US symbol**, not a US one:

   ```
   GET /v1/market/quote/VWCE.AS     → expect a real price, not 404
   GET /v1/market/quote/AAPL        → still works (regression check)
   ```

   Then confirm no `fmp_fallback_skipped ... reason=tier` lines remain in the api logs for
   symbols you expect to be covered.

5. **Purge poisoned cache rows if any exist.** `QuoteCache` rows are keyed by provider name, so
   entries written while a different provider was active are already ignored. But zero-priced
   rows written *before* the 2026-08-20 fix, under the current provider name, will still be
   served until their TTL expires. Delete rows for affected symbols after deploying.

## Related

- `MARKET_PROVIDER`, `FINNHUB_API_KEY`, `FMP_API_KEY`, `FMP_SYMBOL_ACCESS_TIER` — all in the
  `api-env` SealedSecret; the api Deployment takes them via `envFrom`, so none appear in the
  Deployment YAML.
- Do not confuse this with the IBKR *market data* provider (`IBKR_API_BASE_URL`, Client Portal
  Gateway) or the IBKR *statement* feed (`IBKR_SOD_*`). Three unrelated IBKR paths exist.
