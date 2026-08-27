# In-app AI cost controls (ops)

Norviq pays LLM usage for **in-app** chat, insight cards, and proactive tips.
MCP is BYO-LLM — users pay Claude/Cursor/ChatGPT; see MCP README.

## Gates (already in code)

| Control | Where | Default |
|---------|--------|---------|
| `AI_ENABLED` | All in-app LLM routes + tips job | `true` |
| `AI_PROACTIVE_TIPS_ENABLED` | Tips background job only | `true` |
| `AI_DAILY_LIMIT` | Redis day-bucket on `/v1/ai/chat` + `/v1/ai/insights/*` | `50` |
| `AI_FREE_MONTHLY_LIMIT` | Free users on `/v1/ai/assistant/*` | `5` |
| Route rate limit | `RateLimitMiddleware` 20/min `ratelimit:ai` | 20/min |
| Pro entitlement | `requirePremium(.aiInsights)` on chat + insights | Pro/trial |
| Free monthly | `AIAssistantUsage` month counter | 5 turns |
| Tips | Pro only + user preference + meaningful-spend heuristic | — |
| Empty API key | `DisabledOpenAIChatClient` | no spend |

## Kill switch

```bash
AI_ENABLED=false
```

Returns `503` on chat / insights / assistant turns. Tips job no-ops.

Tips only:

```bash
AI_PROACTIVE_TIPS_ENABLED=false
```

## Cheaper models

| Workload | Env | OpenAI default | OpenRouter default |
|----------|-----|----------------|--------------------|
| Chat | `AI_CHAT_MODEL` / `AI_MODEL` | `gpt-5.6-terra` | `anthropic/claude-sonnet-4.6` |
| Tips | `AI_TIPS_MODEL` | `gpt-5.6-luna` | `google/gemini-3.5-flash` |

Prefer flash/luna (or DeepSeek) for tips; keep stronger chat model only if quality requires it.

## Plan-based model routing

OpenRouter does not know who is a paying Norviq user — it runs whatever slug it
is handed and bills for it. The plan is therefore read on this server and picks
the chain, rather than letting a free user's turn start on the paid model and
waiting for a failure to demote it.

| Plan | Chain |
|------|-------|
| Free | `AI_FREE_PROVIDERS` only — zero-cost slugs |
| Pro  | `AI_MODEL` → `AI_PRO_FALLBACK_PROVIDERS` → the free chain |

The free chain sits under Pro on purpose: the OpenRouter account can be at zero
balance, and a Pro user hitting a 402 should get a weaker answer rather than no
answer.

A slug in `AI_FREE_PROVIDERS` that is not `:free`-suffixed (or `openrouter/free`)
is dropped at boot rather than sent, so an env-var typo cannot bill a free user.

Plan comes from the same `EntitlementResolver` the rest of billing uses, so
`BILLING_PREMIUM_EMAILS`, an active trial, and a `lifetime_pro` coupon all route
to the Pro chain without a subscription.

Scope: user-attributed assistant turns. `/v1/ai/chat` and `/v1/ai/insights/*` are
Pro-gated already, so they stay on the Pro chain. Background work (tips job,
why-moved, sentiment themes, receipt OCR) has no requesting user's plan to read
and also stays on the Pro chain. A user on their own key (BYOK) is not routed.

Rollback: `AI_PLAN_ROUTING_ENABLED=false` restores the single pre-2026-08-27
chain, where a free user keeps the paid model until it fails.

What to watch: `ai_plan_routing` at boot lists both chains; `ai_plan_route` (debug)
names the plan and lead model per turn; `ai_completion` logs the slug that
actually ran.

## Production checklist

1. Set `AI_PROVIDER` + key (`OPENAI_API_KEY` or `OPENROUTER_API_KEY`).
2. Set `AI_DAILY_LIMIT` (start ~20–50 depending on Pro volume).
3. Confirm Redis up — daily cap fails closed in production without Redis.
4. Keep `AI_ENABLED=true` unless emergency stop.
5. Monitor provider invoices + `ai_daily:*` Redis keys / 429 responses.
