#!/bin/bash
# Burst Test Script — Demonstrates token-based rate limiting (SC #2)
#
# Sends rapid inference requests to consume a subscription's token quota,
# triggering HTTP 429 responses when the limit is reached.
#
# Usage:
#   ./scripts/burst-test.sh [API_KEY] [TIER]
#
# Arguments:
#   API_KEY  — API key for the subscription to test (required)
#   TIER     — Tier label for display (optional, default: "unknown")
#
# Prerequisites:
#   - scripts/config.env populated
#   - Model serving and MaaS gateway operational
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/config.env" ]; then
  echo "ERROR: scripts/config.env not found."
  exit 1
fi
source "$SCRIPT_DIR/config.env"

API_KEY="${1:-}"
TIER="${2:-unknown}"

if [ -z "$API_KEY" ]; then
  echo "Usage: $0 <API_KEY> [TIER]"
  echo ""
  echo "Example:"
  echo "  $0 sk-team-c-abc123 basic"
  echo ""
  echo "This will send burst requests until a 429 rate limit response is received."
  exit 1
fi

ENDPOINT="https://${MAAS_GW_HOST}/llm-inference/${MODEL_NAME}/v1/chat/completions"
MAX_REQUESTS=50
TOTAL_TOKENS=0
REQUEST_COUNT=0
RATE_LIMITED=false

echo "========================================================================"
echo "  BURST TEST — Token Rate Limiting Demonstration"
echo "========================================================================"
echo ""
echo "  Endpoint:  $ENDPOINT"
echo "  Tier:      $TIER"
echo "  Strategy:  Large prompts to consume token quota quickly"
echo ""
echo "  Rate limits by tier:"
echo "    premium:  500,000 tokens/hour"
echo "    standard: 100,000 tokens/hour"
echo "    basic:     50,000 tokens/hour"
echo ""
echo "========================================================================"
echo ""

LARGE_PROMPT="Explain in comprehensive detail the entire history of artificial intelligence, \
starting from its philosophical origins in ancient Greece, through the Dartmouth conference, \
the AI winters, the rise of machine learning, deep learning revolution, transformer architectures, \
large language models, and the current state of AI in 2026. Cover every major milestone, \
researcher, and breakthrough. Be as thorough as possible."

for i in $(seq 1 $MAX_REQUESTS); do
  RESP_FILE=$(mktemp)
  HTTP_CODE=$(curl -sk -w "%{http_code}" -o "$RESP_FILE" \
    "$ENDPOINT" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL_NAME}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"$LARGE_PROMPT\"}],
      \"max_tokens\": 2000
    }" 2>/dev/null)

  REQUEST_COUNT=$((REQUEST_COUNT + 1))

  if [ "$HTTP_CODE" = "429" ]; then
    RATE_LIMITED=true
    echo ""
    echo "  [$i] HTTP 429 — RATE LIMIT HIT"
    echo ""
    echo "  Rate limit response:"
    cat "$RESP_FILE" | python3 -m json.tool 2>/dev/null || cat "$RESP_FILE"
    rm -f "$RESP_FILE"
    break
  elif [ "$HTTP_CODE" = "200" ]; then
    TOKENS=$(cat "$RESP_FILE" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('usage',{}).get('total_tokens',0))
except:
    print(0)
" 2>/dev/null)
    TOTAL_TOKENS=$((TOTAL_TOKENS + ${TOKENS:-0}))
    printf "  [%2d] HTTP 200 — tokens this request: %s | cumulative: %s\n" "$i" "${TOKENS:-?}" "$TOTAL_TOKENS"
  else
    echo "  [$i] HTTP $HTTP_CODE — unexpected response"
    cat "$RESP_FILE" 2>/dev/null | head -3
    rm -f "$RESP_FILE"
    break
  fi

  rm -f "$RESP_FILE"
done

echo ""
echo "========================================================================"
echo "  RESULTS"
echo "========================================================================"
echo ""
echo "  Requests sent:    $REQUEST_COUNT"
echo "  Tokens consumed:  $TOTAL_TOKENS"
echo "  Rate limited:     $RATE_LIMITED"
echo ""

if [ "$RATE_LIMITED" = "true" ]; then
  echo "  PASS: Token-based rate limiting is enforced."
  echo "        The $TIER tier was throttled after consuming its quota."
  echo ""
  echo "  Next step: Verify other tiers are unaffected:"
  echo "    curl -sk -w 'HTTP %{http_code}' <ENDPOINT> -H 'Authorization: Bearer <PREMIUM_KEY>' ..."
  echo ""
  exit 0
else
  echo "  NOTE: Rate limit was not triggered within $MAX_REQUESTS requests."
  echo "        This may mean:"
  echo "          - The tier has a high quota (e.g., premium = 500K tokens/hr)"
  echo "          - The rate limit window has recently reset"
  echo "          - Limitador counters need more requests to trigger"
  echo ""
  echo "  Try again with more requests or use a lower-tier subscription."
  exit 1
fi
