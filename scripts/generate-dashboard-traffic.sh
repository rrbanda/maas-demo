#!/bin/bash
# Generate traffic for MaaS observability dashboard
#
# Usage:
#   export API_KEY="sk-oai-..."
#   export MAAS_GW="<gateway-elb-hostname>"
#   ./scripts/generate-dashboard-traffic.sh [num_requests]
#
# Modes:
#   ./scripts/generate-dashboard-traffic.sh         # 10 mixed requests (default)
#   ./scripts/generate-dashboard-traffic.sh 100     # 100 authenticated requests
#   ./scripts/generate-dashboard-traffic.sh 10000   # high volume for dashboard

set -euo pipefail

MAAS_GW="${MAAS_GW:?Set MAAS_GW (gateway ELB hostname)}"
API_KEY="${API_KEY:?Set API_KEY (sk-oai-...)}"
MODEL="${MODEL:-gemma2-9b-fp8}"
MODEL_PATH="/models-as-a-service/${MODEL}/v1/chat/completions"
NUM_REQUESTS=${1:-10}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PROMPTS=(
  "What is 2+2?"
  "Explain AI in one sentence"
  "Write hello world in Python"
  "What is Kubernetes?"
  "Name 3 colors"
  "What is machine learning?"
  "Define cloud computing"
  "What is an API?"
  "Explain containers briefly"
  "What is OpenShift?"
  "Hello"
  "What is vLLM?"
  "Define rate limiting"
  "What is a GPU?"
  "Explain inference"
)

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}MaaS Dashboard Traffic Generator${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "   ${BOLD}Gateway:${NC}  https://$MAAS_GW"
echo -e "   ${BOLD}Model:${NC}    $MODEL"
echo -e "   ${BOLD}Path:${NC}     $MODEL_PATH"
echo -e "   ${BOLD}Requests:${NC} $NUM_REQUESTS"
echo -e "   ${BOLD}API Key:${NC}  ${API_KEY:0:20}..."
echo ""

SUCCESS=0
FAIL_401=0
FAIL_429=0
FAIL_OTHER=0
TOTAL_TOKENS=0

send_request() {
  local prompt="$1"
  local max_tokens="${2:-10}"

  local resp
  resp=$(curl -sk -w "\n__HTTP__%{http_code}" --max-time 30 \
    "https://${MAAS_GW}${MODEL_PATH}" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}],\"max_tokens\":$max_tokens}" 2>/dev/null || echo "__HTTP__000")

  local http_code
  http_code=$(echo "$resp" | grep "__HTTP__" | sed 's/.*__HTTP__//')
  local body
  body=$(echo "$resp" | grep -v "__HTTP__")

  local tokens=0
  if [ "$http_code" = "200" ]; then
    tokens=$(echo "$body" | grep -o '"total_tokens":[0-9]*' | head -1 | sed 's/"total_tokens"://' || echo "0")
    TOTAL_TOKENS=$((TOTAL_TOKENS + ${tokens:-0}))
    SUCCESS=$((SUCCESS + 1))
  elif [ "$http_code" = "401" ]; then
    FAIL_401=$((FAIL_401 + 1))
  elif [ "$http_code" = "429" ]; then
    FAIL_429=$((FAIL_429 + 1))
  else
    FAIL_OTHER=$((FAIL_OTHER + 1))
  fi

  echo "$http_code $tokens"
}

if [ "$NUM_REQUESTS" -le 20 ]; then
  echo -e "${BLUE}── Sending $NUM_REQUESTS requests (detailed mode) ──${NC}"
  echo ""

  # 2 unauthenticated
  echo -e "   ${DIM}[unauth]${NC} No API key..."
  CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
    "https://${MAAS_GW}${MODEL_PATH}" \
    -H "Content-Type: application/json" \
    -d '{"model":"'$MODEL'","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>/dev/null)
  echo -e "            HTTP ${RED}${BOLD}$CODE${NC} (expected 401)"
  FAIL_401=$((FAIL_401 + 1))

  echo -e "   ${DIM}[bad key]${NC} Invalid API key..."
  CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
    "https://${MAAS_GW}${MODEL_PATH}" \
    -H "Authorization: Bearer invalid-key" \
    -H "Content-Type: application/json" \
    -d '{"model":"'$MODEL'","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>/dev/null)
  echo -e "            HTTP ${RED}${BOLD}$CODE${NC} (expected 401/403)"
  FAIL_OTHER=$((FAIL_OTHER + 1))

  echo ""
  REMAINING=$((NUM_REQUESTS - 2))
  [ "$REMAINING" -lt 1 ] && REMAINING=1

  for i in $(seq 1 "$REMAINING"); do
    PROMPT_IDX=$(( (i - 1) % ${#PROMPTS[@]} ))
    PROMPT="${PROMPTS[$PROMPT_IDX]}"
    RESULT=$(send_request "$PROMPT" 10)
    CODE=$(echo "$RESULT" | awk '{print $1}')
    TOKENS=$(echo "$RESULT" | awk '{print $2}')

    if [ "$CODE" = "200" ]; then
      printf "   ${DIM}[%3d/%d]${NC}  HTTP ${GREEN}${BOLD}%s${NC}  tokens=%-4s  ${DIM}%s${NC}\n" \
        "$((i+2))" "$NUM_REQUESTS" "$CODE" "$TOKENS" "$PROMPT"
    elif [ "$CODE" = "429" ]; then
      printf "   ${DIM}[%3d/%d]${NC}  HTTP ${YELLOW}${BOLD}%s${NC}  ${DIM}rate limited${NC}\n" \
        "$((i+2))" "$NUM_REQUESTS" "$CODE"
      sleep 2
    else
      printf "   ${DIM}[%3d/%d]${NC}  HTTP ${RED}${BOLD}%s${NC}\n" "$((i+2))" "$NUM_REQUESTS" "$CODE"
    fi
    sleep 0.3
  done

else
  echo -e "${BLUE}── Sending $NUM_REQUESTS requests (high volume mode) ──${NC}"
  echo ""

  BATCH_SIZE=50
  BATCH_NUM=0
  for i in $(seq 1 "$NUM_REQUESTS"); do
    PROMPT_IDX=$(( (i - 1) % ${#PROMPTS[@]} ))
    PROMPT="${PROMPTS[$PROMPT_IDX]}"
    send_request "$PROMPT" 5 > /dev/null &

    if (( i % BATCH_SIZE == 0 )); then
      wait
      BATCH_NUM=$((BATCH_NUM + 1))
      DONE=$((BATCH_NUM * BATCH_SIZE))
      PCT=$(( DONE * 100 / NUM_REQUESTS ))
      printf "   ${DIM}[%d/%d]${NC}  %d%% complete  (success=%d  429=%d  errors=%d  tokens=%d)\n" \
        "$DONE" "$NUM_REQUESTS" "$PCT" "$SUCCESS" "$FAIL_429" "$FAIL_OTHER" "$TOTAL_TOKENS"
    fi
  done
  wait
fi

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Results${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "   ${GREEN}${BOLD}Success (200):${NC}     $SUCCESS"
echo -e "   ${RED}Unauthorized (401):${NC} $FAIL_401"
echo -e "   ${YELLOW}Rate Limited (429):${NC} $FAIL_429"
echo -e "   ${RED}Other Errors:${NC}       $FAIL_OTHER"
echo -e "   ${BOLD}Total Tokens:${NC}       $TOTAL_TOKENS"
echo ""
echo -e "   ${DIM}View dashboard: https://rh-ai.apps.cluster-6crhb.6crhb.sandbox1011.opentlc.com${NC}"
echo ""
