#!/usr/bin/env bash
# SUPERSEDED — DO NOT RUN AGAINST THE LIVE VPS.
#
# Since 2026-07-29 retrieval runs as Hermes agent cron jobs
# (hermes-ticker-sentiment 30 13,17,21 * * 1-5, hermes-topic-sentiment 0 6 * * *,
# hermes-sentiment-score-ingest 45 6,13,17,21 * * *), not systemd. The timers
# installed below run every 45 minutes — the exact cadence that was disabled on
# purpose because re-scraping a 7-day window that often was ~92% redundant and
# most of the xAI bill. Running this double-schedules the ingest and undoes that.
#
# Kept for reference and for standing the pipeline up somewhere new. See README.md.
#
# Deploys the xAI Agent Tools ingest (ticker + topic) to the Hermes VPS and
# installs systemd timers.
#
#   ./deploy-ticker-scraper.sh [root@78.46.192.73]
#
# Requires: XAI_API_KEY present in /root/.hermes/.env on the VPS (canonical
# Hermes env; /opt/data/.env also read). Verify with:
#   ssh <host> "grep -c '^XAI_API_KEY=' /root/.hermes/.env"
# NOTE: the live verification step needs xAI API credits; without credits the
# timers still install fine and runs succeed automatically once topped up.
set -euo pipefail

HOST="${1:-root@78.46.192.73}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR=/root/.hermes/financial-pipeline

echo "==> Uploading scraper + config"
scp -q "${SCRIPT_DIR}/ticker_sentiment_scraper.py" "${HOST}:${REMOTE_DIR}/scripts/ticker_sentiment_scraper.py"
# Config: only install if absent (never clobber tuned settings).
ssh "${HOST}" "test -f ${REMOTE_DIR}/scraper_config.json" || \
  scp -q "${SCRIPT_DIR}/scraper_config.json" "${HOST}:${REMOTE_DIR}/scraper_config.json"
ssh "${HOST}" "python3 -m py_compile ${REMOTE_DIR}/scripts/ticker_sentiment_scraper.py"

echo "==> Installing systemd units"
ssh "${HOST}" "cat > /etc/systemd/system/hermes-ticker-scraper.service <<'EOF'
[Unit]
Description=Hermes ticker sentiment ingest (xAI Agent Tools)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 -u /root/.hermes/financial-pipeline/scripts/ticker_sentiment_scraper.py --mode tickers
EOF
cat > /etc/systemd/system/hermes-ticker-scraper.timer <<'EOF'
[Unit]
Description=Run Hermes ticker sentiment ingest every 45 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=45min
RandomizedDelaySec=3min

[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/hermes-topic-ingest.service <<'EOF'
[Unit]
Description=Hermes topic sentiment ingest (xAI Agent Tools)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 -u /root/.hermes/financial-pipeline/scripts/ticker_sentiment_scraper.py --mode topics
EOF
cat > /etc/systemd/system/hermes-topic-ingest.timer <<'EOF'
[Unit]
Description=Run Hermes topic sentiment ingest daily

[Timer]
OnCalendar=*-*-* 06:20:00 UTC
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now hermes-ticker-scraper.timer hermes-topic-ingest.timer
systemctl list-timers hermes-\* --no-pager | head -5"

echo "==> One-shot verification run (tickers, live; tolerated if xAI credits are missing)"
if ! ssh "${HOST}" "python3 -u ${REMOTE_DIR}/scripts/ticker_sentiment_scraper.py --mode tickers 2>&1 | tail -8"; then
  echo "WARN: live run failed — most likely no xAI API credits yet."
  echo "      Timers are installed; runs will succeed automatically once credits are added."
fi

echo "==> Row counts"
ssh "${HOST}" "python3 -c \"
import sqlite3
c = sqlite3.connect('${REMOTE_DIR}/data/finance.sqlite')
print('ticker_posts:', c.execute('SELECT COUNT(*) FROM ticker_posts').fetchone()[0])
print('xai fin_event:', c.execute(\\\"SELECT COUNT(*) FROM fin_event WHERE source='xai_live_search'\\\").fetchone()[0])
\""

cat <<'SUMMARY'

Done. Next:
  - Topic ingest runs daily 06:20 UTC; run once now with:
      ssh root@78.46.192.73 "systemctl start hermes-topic-ingest.service"
  - After topics populate, purge the junk rows:
      ssh root@78.46.192.73 "python3 /root/.hermes/financial-pipeline/scripts/ticker_sentiment_scraper.py --purge-source manual --yes"
  - Backend picks up ticker posts on the next HermesSyncJob tick (<=15 min).
SUMMARY
