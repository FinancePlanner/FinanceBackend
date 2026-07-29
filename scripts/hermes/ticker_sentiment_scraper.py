#!/usr/bin/env python3
"""Hermes ticker/topic sentiment ingest via the xAI Agent Tools API
(/v1/responses with server-side x_search / web_search tools).

Modes:
  tickers  Search X for notable posts per tracked symbol; write ticker_posts
           rows served by finance_api_server.py /finance/ticker/{symbol}/posts.
  topics   Search X + news per financial topic; write schema-compatible
           fin_event rows (and append raw_events.jsonl) so /finance/summary
           and /finance/sentiment reflect real financial content.

No HTML scraping: Grok performs the search server-side and returns citations.
Requires XAI_API_KEY (loaded from /root/.hermes/.env, /opt/data/.env, or the
process environment) and available xAI API credits.

Examples:
  python3 ticker_sentiment_scraper.py --mode tickers
  python3 ticker_sentiment_scraper.py --mode topics --dry-run
  python3 ticker_sentiment_scraper.py --purge-source manual --yes
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import sqlite3
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

LOG = logging.getLogger("ticker_scraper")

DEFAULT_DB = "/root/.hermes/financial-pipeline/data/finance.sqlite"
DEFAULT_CONFIG = "/root/.hermes/financial-pipeline/scraper_config.json"
DEFAULT_RAW_JSONL = "/root/.hermes/financial-pipeline/data/raw_events.jsonl"
# Agent Tools API (the old chat.completions Live Search returns HTTP 410).
XAI_URL = "https://api.x.ai/v1/responses"

STATUS_ID_RE = re.compile(r"(?:x\.com|twitter\.com)/[^/]+/status/(\d+)")

TICKER_POSTS_SCHEMA = """
CREATE TABLE IF NOT EXISTS ticker_posts (
    event_id TEXT PRIMARY KEY,
    symbol TEXT NOT NULL,
    author TEXT,
    author_handle TEXT,
    text TEXT,
    url TEXT,
    sentiment TEXT,
    sentiment_score REAL,
    confidence REAL,
    posted_at TEXT NOT NULL,
    ingested_at TEXT NOT NULL
)
"""


def load_env_files() -> None:
    """Load shell-style .env files the way the other Hermes scripts do.

    /root/.hermes/.env is the canonical Hermes agent env (holds XAI_API_KEY);
    /opt/data/.env is the legacy location other pollers read."""
    for env_path in (Path("/root/.hermes/.env"), Path("/opt/data/.env")):
        if not env_path.exists():
            continue
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):]
            if "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip()
            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                val = val[1:-1]
            os.environ.setdefault(key, val)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def load_config(path: str) -> dict:
    defaults = {
        "model": os.environ.get("GROK_MODEL", "grok-4.3"),
        "tickers": ["AMD", "NVDA", "AAPL"],
        "notable_handles": [],
        "topics": {
            "Housing": "housing market, mortgage rates, rent prices, home affordability",
            "Savings": "savings rates, high-yield savings accounts, emergency funds",
            "Insurance": "auto home life health insurance premiums and coverage trends",
            "Retirement": "retirement planning, 401k, IRA, pensions, social security",
            "NetWorth": "personal net worth building, wealth tracking, FIRE movement",
            "Taxes": "personal income tax, deductions, tax planning changes",
            "Debt": "credit card debt, loans, interest rates, debt payoff",
            "Crypto": "bitcoin ethereum crypto market moves and regulation",
            "Stocks": "stock market outlook, earnings, notable equity moves",
            "Expenses": "cost of living, inflation, household budgets",
        },
        "days_back": 7,
        "max_posts_per_symbol": 10,
        "max_items_per_topic": 10,
        "max_search_results": 20,
        "request_timeout_seconds": 90,
    }
    p = Path(path)
    if p.exists():
        defaults.update(json.loads(p.read_text()))
    return defaults


# ── xAI client ────────────────────────────────────────────────────────────────

def xai_chat(payload: dict, timeout: int, retries: int = 3) -> dict:
    api_key = os.environ.get("XAI_API_KEY", "").strip()
    if not api_key:
        raise SystemExit("XAI_API_KEY is not set (checked /root/.hermes/.env, /opt/data/.env, environment).")

    body = json.dumps(payload).encode("utf-8")
    last_error: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            req = Request(
                XAI_URL,
                data=body,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {api_key}",
                },
            )
            with urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:300]
            last_error = RuntimeError(f"xAI HTTP {e.code}: {detail}")
            # 4xx (except 429) will not improve on retry.
            if 400 <= e.code < 500 and e.code != 429:
                break
        except (URLError, TimeoutError, json.JSONDecodeError) as e:
            last_error = e
        sleep_s = 5 * attempt
        LOG.warning("xAI call failed (attempt %d/%d): %s — retrying in %ds", attempt, retries, last_error, sleep_s)
        time.sleep(sleep_s)
    raise RuntimeError(f"xAI request failed after {retries} attempts: {last_error}")


def extract_json_array(content: str) -> list:
    """Parse the model reply into a list, tolerating fences and wrappers."""
    text = content.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text.strip())
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        # Last resort: grab the outermost JSON array in the text.
        match = re.search(r"\[.*\]", text, re.DOTALL)
        if not match:
            raise
        parsed = json.loads(match.group(0))
    if isinstance(parsed, dict):
        for key in ("posts", "items", "results"):
            if isinstance(parsed.get(key), list):
                return parsed[key]
        return []
    return parsed if isinstance(parsed, list) else []


def log_usage(label: str, response: dict) -> None:
    usage = response.get("usage") or {}
    LOG.info(
        "usage %s input=%s output=%s total=%s",
        label,
        usage.get("input_tokens", usage.get("prompt_tokens")),
        usage.get("output_tokens", usage.get("completion_tokens")),
        usage.get("total_tokens"),
    )


def extract_output_text(response: dict) -> str:
    """Concatenate output_text parts from a /v1/responses payload."""
    parts = []
    for item in response.get("output") or []:
        if item.get("type") != "message":
            continue
        for piece in item.get("content") or []:
            if piece.get("type") == "output_text" and piece.get("text"):
                parts.append(piece["text"])
    return "\n".join(parts)


# ── Normalization ─────────────────────────────────────────────────────────────

def clamp(value, lo: float, hi: float, default: float | None):
    try:
        return max(lo, min(hi, float(value)))
    except (TypeError, ValueError):
        return default


def normalize_sentiment(raw, allowed: tuple[str, ...], fallback: str) -> str:
    value = str(raw or "").strip().lower()
    return value if value in allowed else fallback


def post_event_id(item: dict) -> str:
    url = str(item.get("url") or "")
    match = STATUS_ID_RE.search(url)
    if match:
        return f"x-{match.group(1)}"
    basis = f"{item.get('author_handle') or item.get('author') or ''}|{item.get('text') or ''}"
    return "xh-" + hashlib.sha256(basis.encode("utf-8")).hexdigest()[:32]


def parse_posted_at(raw, days_back: int) -> str:
    """Best-effort ISO timestamp; fall back to the window midpoint so the row
    still lands inside the API's date filters."""
    if raw:
        text = str(raw).strip().rstrip("Z")
        candidates = []
        if len(text) >= 19:
            candidates.append(text[:19] + "+00:00")   # full datetime, force UTC
        if len(text) >= 10:
            candidates.append(text[:10] + "T12:00:00+00:00")  # date only → noon UTC
        for candidate in candidates:
            try:
                datetime.fromisoformat(candidate)
                return candidate
            except ValueError:
                continue
    fallback = datetime.now(timezone.utc) - timedelta(days=max(1, days_back // 2))
    return fallback.isoformat(timespec="seconds")


# ── Ticker mode ───────────────────────────────────────────────────────────────

def build_ticker_payload(cfg: dict, symbol: str) -> dict:
    from_date = (datetime.now(timezone.utc) - timedelta(days=cfg["days_back"])).date().isoformat()
    x_search_tool: dict = {"type": "x_search", "from_date": from_date}
    handles = [h.lstrip("@") for h in cfg.get("notable_handles", []) if h.strip()][:20]
    if handles:
        x_search_tool["allowed_x_handles"] = handles

    prompt = (
        f"Search X for substantive recent posts about ${symbol} (the stock). "
        f"Only include posts with an actual investment thesis, analysis, or strong opinion from credible accounts. "
        f"Exclude giveaways, bots, engagement bait, pure price screenshots, and spam.\n\n"
        f"Return STRICT JSON only — an array of at most {cfg['max_posts_per_symbol']} objects, no prose, each with:\n"
        f'  "author": display name,\n'
        f'  "author_handle": handle without @,\n'
        f'  "url": direct https://x.com/<handle>/status/<id> link,\n'
        f'  "text": verbatim quote of the post, max 500 chars,\n'
        f'  "sentiment": "bullish" | "bearish" | "neutral",\n'
        f'  "sentiment_score": number in [-1, 1],\n'
        f'  "confidence": number in [0, 1],\n'
        f'  "posted_at": ISO 8601 date or datetime of the post.\n'
        f"If you find nothing substantive, return []."
    )

    return {
        "model": cfg["model"],
        "input": [
            {"role": "system", "content": "You extract structured financial sentiment data. You reply with strict JSON only."},
            {"role": "user", "content": prompt},
        ],
        "tools": [x_search_tool],
    }


def insert_ticker_post_rows(conn, symbol: str, items: list, cfg: dict, dry_run: bool) -> int:
    """Validate/normalize ticker post dicts and insert; returns inserted count."""
    inserted = 0
    for item in items[: cfg["max_posts_per_symbol"]]:
        text = str(item.get("text") or "").strip()
        if not text:
            continue
        row = (
            post_event_id(item),
            symbol,
            (str(item.get("author") or "").strip() or None),
            (str(item.get("author_handle") or "").strip().lstrip("@") or None),
            text[:500],
            (str(item.get("url") or "").strip() or None),
            normalize_sentiment(item.get("sentiment"), ("bullish", "bearish", "neutral"), "neutral"),
            clamp(item.get("sentiment_score"), -1.0, 1.0, None),
            clamp(item.get("confidence"), 0.0, 1.0, None),
            parse_posted_at(item.get("posted_at"), cfg["days_back"]),
            now_iso(),
        )
        if dry_run:
            LOG.info("dry-run ticker_post %s %s @%s", symbol, row[0], row[3])
            continue
        cursor = conn.execute(
            "INSERT OR IGNORE INTO ticker_posts "
            "(event_id, symbol, author, author_handle, text, url, sentiment, sentiment_score, confidence, posted_at, ingested_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            row,
        )
        inserted += cursor.rowcount
    if not dry_run:
        conn.commit()
    return inserted


def run_tickers(cfg: dict, db_path: str, dry_run: bool) -> None:
    conn = sqlite3.connect(db_path)
    conn.execute(TICKER_POSTS_SCHEMA)
    total_inserted = 0
    attempted = 0
    failed = 0

    for symbol in cfg["tickers"]:
        symbol = symbol.strip().lstrip("$").upper()
        if not symbol:
            continue
        attempted += 1
        try:
            response = xai_chat(build_ticker_payload(cfg, symbol), cfg["request_timeout_seconds"])
        except RuntimeError as e:
            LOG.error("symbol=%s fetch failed: %s", symbol, e)
            failed += 1
            continue
        log_usage(f"tickers:{symbol}", response)

        content = extract_output_text(response)
        try:
            items = extract_json_array(content)
        except (json.JSONDecodeError, ValueError):
            LOG.error("symbol=%s unparseable model output: %.200s", symbol, content)
            failed += 1
            continue

        inserted = insert_ticker_post_rows(conn, symbol, items, cfg, dry_run)
        total_inserted += inserted
        LOG.info("symbol=%s extracted=%d inserted=%d", symbol, len(items), inserted)

    conn.close()
    LOG.info("tickers done inserted=%d attempted=%d failed=%d", total_inserted, attempted, failed)

    # Exit non-zero when nothing got through. Previously every symbol could fail
    # (an invalid XAI_API_KEY does exactly that) and the process still exited 0,
    # so systemd reported the timer as successful and the ingest silently froze
    # for days. A hard failure is what makes the timer honest.
    if attempted and failed == attempted:
        raise SystemExit(
            f"all {attempted} symbols failed — ingest produced nothing "
            "(check XAI_API_KEY validity and xAI credits)"
        )


# ── Topic mode ────────────────────────────────────────────────────────────────

def build_topic_payload(cfg: dict, topic: str, hint: str) -> dict:
    from_date = (datetime.now(timezone.utc) - timedelta(days=cfg["days_back"])).date().isoformat()
    prompt = (
        f"Search X and recent news for the most substantive posts/articles about: {hint}. "
        f"Personal-finance angle preferred; skip spam and engagement bait.\n\n"
        f"Return STRICT JSON only — an array of at most {cfg['max_items_per_topic']} objects, each with:\n"
        f'  "title": short headline,\n'
        f'  "summary": 1-2 sentence factual summary,\n'
        f'  "url": source link,\n'
        f'  "author": author or outlet name,\n'
        f'  "sentiment": "positive" | "neutral" | "negative" (tone for a person\'s finances),\n'
        f'  "sentiment_score": number in [-1, 1],\n'
        f'  "published_at": ISO 8601 date if known.\n'
        f"If nothing substantive, return []."
    )
    return {
        "model": cfg["model"],
        "input": [
            {"role": "system", "content": "You extract structured financial news/sentiment data. You reply with strict JSON only."},
            {"role": "user", "content": prompt},
        ],
        "tools": [
            {"type": "x_search", "from_date": from_date},
            {"type": "web_search"},
        ],
    }


def insert_topic_item_rows(conn, raw_path: Path, topic: str, items: list, cfg: dict, dry_run: bool) -> int:
    """Validate/normalize topic item dicts into fin_event rows; returns inserted count."""
    inserted = 0
    for item in items[: cfg["max_items_per_topic"]]:
        url = str(item.get("url") or "").strip()
        title = str(item.get("title") or "").strip()
        if not title and not url:
            continue
        observed_at = parse_posted_at(item.get("published_at"), cfg["days_back"])
        event_id = hashlib.sha256(f"{url or title}|{observed_at[:10]}".encode("utf-8")).hexdigest()
        event = {
            "event_id": event_id,
            "source": "xai_live_search",
            "source_id": url or title,
            "observed_at": observed_at,
            "ingested_at": now_iso(),
            "topic": topic,
            "subcategory": None,
            "payload": {
                "title": title,
                "url": url or None,
                "summary": (str(item.get("summary") or "").strip() or None),
                "author": (str(item.get("author") or "").strip() or None),
            },
            "derived": {},
            "sentiment": {
                "label": normalize_sentiment(item.get("sentiment"), ("positive", "neutral", "negative"), "neutral"),
                "score": clamp(item.get("sentiment_score"), -1.0, 1.0, 0.0),
            },
            "status": "new",
            "version": "v1",
        }
        if dry_run:
            LOG.info("dry-run fin_event %s %s %.60s", topic, event_id[:12], title)
            continue
        cursor = conn.execute(
            "INSERT OR IGNORE INTO fin_event "
            "(event_id, source, source_id, observed_at, ingested_at, topic, subcategory, payload, derived, sentiment, status, version) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                event["event_id"], event["source"], event["source_id"], event["observed_at"],
                event["ingested_at"], event["topic"], event["subcategory"],
                json.dumps(event["payload"], ensure_ascii=False),
                json.dumps(event["derived"]),
                json.dumps(event["sentiment"]),
                event["status"], event["version"],
            ),
        )
        if cursor.rowcount:
            with raw_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(event, ensure_ascii=False) + "\n")
        inserted += cursor.rowcount
    if not dry_run:
        conn.commit()
    return inserted


def run_topics(cfg: dict, db_path: str, raw_jsonl: str, dry_run: bool) -> None:
    conn = sqlite3.connect(db_path)
    raw_path = Path(raw_jsonl)
    total_inserted = 0
    attempted = 0
    failed = 0

    for topic, hint in cfg["topics"].items():
        attempted += 1
        try:
            response = xai_chat(build_topic_payload(cfg, topic, hint), cfg["request_timeout_seconds"])
        except RuntimeError as e:
            LOG.error("topic=%s fetch failed: %s", topic, e)
            failed += 1
            continue
        log_usage(f"topics:{topic}", response)

        content = extract_output_text(response)
        try:
            items = extract_json_array(content)
        except (json.JSONDecodeError, ValueError):
            LOG.error("topic=%s unparseable model output: %.200s", topic, content)
            failed += 1
            continue

        inserted = insert_topic_item_rows(conn, raw_path, topic, items, cfg, dry_run)
        total_inserted += inserted
        LOG.info("topic=%s extracted=%d inserted=%d", topic, len(items), inserted)

    conn.close()
    LOG.info("topics done inserted=%d attempted=%d failed=%d", total_inserted, attempted, failed)

    # Same reasoning as run_tickers: a total failure must not exit 0.
    if attempted and failed == attempted:
        raise SystemExit(
            f"all {attempted} topics failed — ingest produced nothing "
            "(check XAI_API_KEY validity and xAI credits)"
        )


# ── File ingest mode (Hermes agent hand-off) ─────────────────────────────────
# The Hermes agent (SuperGrok OAuth — no xAI API key needed) searches X itself
# and drops a JSON file; this mode validates, dedupes, and inserts it.
# Expected shape (either key optional):
#   {
#     "tickers": [{"symbol": "AMD", "author": ..., "author_handle": ..., "url": ...,
#                  "text": ..., "sentiment": "bullish|bearish|neutral",
#                  "sentiment_score": -1..1, "confidence": 0..1, "posted_at": ISO}],
#     "topics":  [{"topic": "Housing", "title": ..., "summary": ..., "url": ...,
#                  "author": ..., "sentiment": "positive|neutral|negative",
#                  "sentiment_score": -1..1, "published_at": ISO}]
#   }

def run_ingest_file(cfg: dict, db_path: str, raw_jsonl: str, file_path: str, dry_run: bool) -> None:
    data = json.loads(Path(file_path).read_text(encoding="utf-8"))
    if isinstance(data, list):
        # Bare array: assume ticker posts (each item must carry "symbol").
        data = {"tickers": data}

    conn = sqlite3.connect(db_path)
    conn.execute(TICKER_POSTS_SCHEMA)
    raw_path = Path(raw_jsonl)

    ticker_items = data.get("tickers") or []
    by_symbol: dict[str, list] = {}
    skipped = 0
    for item in ticker_items:
        symbol = str(item.get("symbol") or "").strip().lstrip("$").upper()
        if not symbol:
            skipped += 1
            continue
        by_symbol.setdefault(symbol, []).append(item)
    tickers_inserted = 0
    for symbol, items in by_symbol.items():
        inserted = insert_ticker_post_rows(conn, symbol, items, cfg, dry_run)
        tickers_inserted += inserted
        LOG.info("ingest-file symbol=%s items=%d inserted=%d", symbol, len(items), inserted)

    topic_items = data.get("topics") or []
    by_topic: dict[str, list] = {}
    for item in topic_items:
        topic = str(item.get("topic") or "").strip()
        if not topic:
            skipped += 1
            continue
        by_topic.setdefault(topic, []).append(item)
    topics_inserted = 0
    for topic, items in by_topic.items():
        inserted = insert_topic_item_rows(conn, raw_path, topic, items, cfg, dry_run)
        topics_inserted += inserted
        LOG.info("ingest-file topic=%s items=%d inserted=%d", topic, len(items), inserted)

    conn.close()
    LOG.info(
        "ingest-file done file=%s ticker_posts_inserted=%d fin_events_inserted=%d skipped=%d",
        file_path, tickers_inserted, topics_inserted, skipped,
    )


# ── Maintenance ───────────────────────────────────────────────────────────────

def purge_source(db_path: str, source: str, confirmed: bool) -> None:
    conn = sqlite3.connect(db_path)
    count = conn.execute("SELECT COUNT(*) FROM fin_event WHERE source = ?", (source,)).fetchone()[0]
    if not confirmed:
        LOG.info("would delete %d fin_event rows with source=%s (add --yes to execute)", count, source)
        conn.close()
        return
    conn.execute("DELETE FROM fin_event WHERE source = ?", (source,))
    conn.commit()
    conn.close()
    LOG.info("deleted %d fin_event rows with source=%s", count, source)


def refresh_symbols(config_path: str, url: str, token: str, timeout: int = 30) -> None:
    """Overwrite scraper_config.json 'tickers' from the backend tracked-symbols
    endpoint. Fail-safe: on any error, log a warning and leave the file untouched."""
    import urllib.request

    try:
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        data = json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8"))
        syms = [str(s).strip().upper() for s in (data.get("symbols") or []) if str(s).strip()][:50]
        if not syms:
            LOG.warning("refresh_symbols: empty list, keeping existing config")
            return
        cfg = json.loads(open(config_path).read())
        cfg["tickers"] = syms
        with open(config_path, "w") as fh:
            fh.write(json.dumps(cfg, indent=2))
        LOG.info("refresh_symbols: wrote %d symbols to %s", len(syms), config_path)
    except Exception as e:  # noqa: BLE001 — never let a refresh failure abort the scrape
        LOG.warning("refresh_symbols failed (%s); keeping existing config", e)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=["tickers", "topics", "ingest-file"], help="ingest mode")
    parser.add_argument("--file", help="JSON file produced by the Hermes agent (required for --mode ingest-file)")
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--raw-jsonl", default=DEFAULT_RAW_JSONL)
    parser.add_argument("--dry-run", action="store_true", help="fetch + parse but do not write")
    parser.add_argument("--purge-source", metavar="SOURCE", help="delete fin_event rows with this source, then exit")
    parser.add_argument("--yes", action="store_true", help="confirm --purge-source deletion")
    parser.add_argument("--refresh-symbols", metavar="URL",
                        help="fetch top-N tickers from the backend tracked-symbols endpoint into scraper_config.json, then exit")
    args = parser.parse_args()

    if args.refresh_symbols:
        load_env_files()
        token = os.environ.get("INSIGHTS_SYMBOLS_TOKEN", "").strip()
        if not token:
            LOG.warning("refresh_symbols: INSIGHTS_SYMBOLS_TOKEN not set; keeping existing config")
            return
        refresh_symbols(args.config, args.refresh_symbols, token)
        return

    if args.purge_source:
        purge_source(args.db, args.purge_source, args.yes)
        return

    if not args.mode:
        parser.error("--mode is required unless --purge-source is used")

    load_env_files()
    cfg = load_config(args.config)

    if args.mode == "tickers":
        run_tickers(cfg, args.db, args.dry_run)
    elif args.mode == "topics":
        run_topics(cfg, args.db, args.raw_jsonl, args.dry_run)
    else:
        if not args.file:
            parser.error("--mode ingest-file requires --file")
        run_ingest_file(cfg, args.db, args.raw_jsonl, args.file, args.dry_run)


if __name__ == "__main__":
    main()
