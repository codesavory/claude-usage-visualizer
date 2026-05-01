#!/usr/bin/env bash
# Appends synthetic assistant-turn JSONL lines to ~/.claude/projects/<fake>/<uuid>.jsonl
# so the app can be tested against high-burn / near-limit states without a real Claude session.
#
# Usage: ./dev-replay.sh [--rate TOKS_PER_MIN] [--model opus|sonnet|haiku] [--minutes N]
set -euo pipefail

RATE=${RATE:-6000}
MODEL=${MODEL:-opus}
MINUTES=${MINUTES:-10}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rate) RATE="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --minutes) MINUTES="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

case "$MODEL" in
  opus) API_MODEL="claude-opus-4-7" ;;
  sonnet) API_MODEL="claude-sonnet-4-6" ;;
  haiku) API_MODEL="claude-haiku-4-5" ;;
  *) echo "unknown model: $MODEL"; exit 1 ;;
esac

SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
PROJECT_DIR="$HOME/.claude/projects/-tmp-dev-replay-$$"
mkdir -p "$PROJECT_DIR"
FILE="$PROJECT_DIR/$SESSION_ID.jsonl"
touch "$FILE"

echo "Replay session $SESSION_ID"
echo "  file:   $FILE"
echo "  rate:   ${RATE} tok/min"
echo "  model:  $API_MODEL"
echo "  dur:    ${MINUTES} min"
echo "Ctrl-C to stop early."

INTERVAL_SEC=6
PER_TICK=$(( (RATE * INTERVAL_SEC) / 60 ))
TICKS=$(( (MINUTES * 60) / INTERVAL_SEC ))

for (( i=1; i<=TICKS; i++ )); do
  TS=$(python3 -c 'import datetime; print(datetime.datetime.utcnow().isoformat(timespec="milliseconds") + "Z")')
  REQ_ID="sim-$(uuidgen)"
  INPUT=$((PER_TICK / 6))
  OUTPUT=$((PER_TICK / 3))
  CACHE_READ=$((PER_TICK / 2))
  CACHE_CREATE=0
  printf '{"type":"assistant","sessionId":"%s","cwd":"/tmp/dev-replay","requestId":"%s","timestamp":"%s","message":{"id":"%s","model":"%s","role":"assistant","usage":{"input_tokens":%d,"output_tokens":%d,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d}}}\n' \
    "$SESSION_ID" "$REQ_ID" "$TS" "$REQ_ID" "$API_MODEL" \
    "$INPUT" "$OUTPUT" "$CACHE_CREATE" "$CACHE_READ" >> "$FILE"
  sleep "$INTERVAL_SEC"
done

echo "Done. Cleanup: rm -rf '$PROJECT_DIR'"
