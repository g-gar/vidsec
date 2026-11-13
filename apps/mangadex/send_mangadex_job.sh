#!/usr/bin/env bash
# =============================================================================
# send_mangadex_job.sh — Lightweight Job Dispatcher for Flowdata MangaDex
#
# Dispatches a single manga ingestion workload (JobEnvelope) directly to a
# running Flowdata server instance without needing to launch the inotify collector.
#
# Usage:
#   ./send_mangadex_job.sh [options]
#
# Options:
#   -s, --series-id <UUID>     MangaDex series UUID (default: Low Orbit Human)
#   -t, --title <name>         Human-readable series title
#   -c, --chapters <selector>  Chapter selector e.g. "1", "1..5", "latest:3" (default: "1")
#   -l, --lang <lang>          Language code (default: "en")
#   -L, --library <name>       Target Komga library name or ID (optional)
#   -e, --engine <url>         Flowdata Engine endpoint (default: http://127.0.0.1:8080)
#   -h, --help                 Show this help message
#
# Examples:
#   ./send_mangadex_job.sh --series-id "9d45ff11-2385-4179-8663-e0dbb0ebd792"
#   ./send_mangadex_job.sh -s "162146eb-672a-4a05-b3b2-0c6303f9614e" -t "Takopii" -c "1..3"
# =============================================================================

set -euo pipefail

SERIES_ID="9d45ff11-2385-4179-8663-e0dbb0ebd792" # Low Orbit Human (Default)
TITLE="Low Orbit Human"
CHAPTERS="1"
LANG="en"
LIBRARY=""
ENGINE_URL="${ENGINE_URL:-http://127.0.0.1:8080}"

usage() {
    cat <<EOF
Usage: ./send_mangadex_job.sh [options]

Dispatches a standalone JobEnvelope directly to the Flowdata engine endpoint (/v1/jobs).

Options:
  -s, --series-id <UUID>     MangaDex series UUID (default: $SERIES_ID)
  -t, --title <name>         Series title (default: $TITLE)
  -c, --chapters <selector>  Chapter selector: "1", "1..4", "latest:5", "all" (default: $CHAPTERS)
  -l, --lang <lang>          Language code (default: $LANG)
  -L, --library <name>       Target Komga library name or ID (optional)
  -e, --engine <url>         Flowdata Engine URL (default: $ENGINE_URL)
  -h, --help                 Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--series-id)
            SERIES_ID="$2"
            shift 2
            ;;
        -t|--title)
            TITLE="$2"
            shift 2
            ;;
        -c|--chapters)
            CHAPTERS="$2"
            shift 2
            ;;
        -l|--lang)
            LANG="$2"
            shift 2
            ;;
        -L|--library)
            LIBRARY="$2"
            shift 2
            ;;
        -e|--engine)
            ENGINE_URL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Generate timestamp and unique job identifier
TIMESTAMP_NS=$(date +%s%N)
JOB_ID="job_${TIMESTAMP_NS}"

LIBRARY_FIELD=""
if [[ -n "$LIBRARY" ]]; then
    LIBRARY_FIELD=",\"library\":\"${LIBRARY}\""
fi

# Build inner payload JSON string (escaped for JobEnvelope.payload)
INNER_PAYLOAD=$(cat <<EOF
{"series_id":"${SERIES_ID}","title":"${TITLE}","chapters":"${CHAPTERS}","languages":["${LANG}"],"datasource":"mangadex","enabled":true${LIBRARY_FIELD}}
EOF
)

# Escape payload JSON for envelope encapsulation
ESCAPED_PAYLOAD=$(printf '%s' "$INNER_PAYLOAD" | sed 's/"/\\"/g')

# Universal JobEnvelope JSON (ARCH-019)
ENVELOPE_JSON=$(cat <<EOF
{
  "id": "${JOB_ID}",
  "source": "send_mangadex_job_cli",
  "topic": "manga_subscription",
  "payload": "${ESCAPED_PAYLOAD}",
  "timestamp_ns": ${TIMESTAMP_NS}
}
EOF
)

echo "======================================================="
echo " Flowdata MangaDex Job Dispatcher"
echo "======================================================="
echo " Target Endpoint:  ${ENGINE_URL}/v1/jobs"
echo " Job ID:           ${JOB_ID}"
echo " Series Title:     ${TITLE}"
echo " Series ID:        ${SERIES_ID}"
echo " Chapters:         ${CHAPTERS}"
echo " Language:         ${LANG}"
echo "======================================================="

# Verify connectivity before posting
if ! curl -s --connect-timeout 2 "${ENGINE_URL}/health" > /dev/null 2>&1; then
    echo "[!] Warning: Engine at ${ENGINE_URL} not reachable on /health."
    echo "    Make sure the engine is running in daemon/serve mode:"
    echo "    ./run_pipeline.sh --serve (or 'mangadex serve')"
    echo ""
fi

# Dispatch HTTP POST
echo -n "Dispatching JobEnvelope... "
HTTP_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "$ENVELOPE_JSON" \
    "${ENGINE_URL}/v1/jobs" || true)

HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -e '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n 1 | cut -d: -f2)

if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "202" ]]; then
    echo "[SUCCESS] HTTP ${HTTP_STATUS}"
    if [[ -n "$HTTP_BODY" ]]; then
        echo "Response: $HTTP_BODY"
    fi
else
    echo "[FAILED] HTTP ${HTTP_STATUS:-connection_error}"
    if [[ -n "$HTTP_BODY" ]]; then
        echo "Response: $HTTP_BODY"
    fi
    exit 1
fi
