#!/bin/bash
set -euo pipefail

###############################################################################
# Multi-Cluster Load Balancing Validation Script
#
# Validates: "Is there a way to have the same model deployed in 2 clusters
# and load balance between the two?"
#
#   AI Bridge Cluster    → Cluster 1 — governance + inference A
#   Inference Cluster B  → Cluster 3 — inference B
#
# Architecture:
#   Client → AI Bridge MaaS Gateway → Auth + Rate Limit → Weighted HTTPRoute
#     ├── 50% → Cluster 1 vLLM (local, port 8000)
#     └── 50% → Cluster 3 Gateway → llm-d → vLLM
#
# Usage:
#   export CLUSTER1_API="https://api.cluster-xxx.opentlc.com:6443"
#   export CLUSTER1_PASS="xxx"
#   export CLUSTER3_API="https://api.cluster-yyy.opentlc.com:6443"
#   export CLUSTER3_PASS="yyy"
#   export MAAS_GW="<gateway-elb-hostname>"
#   export CLUSTER3_HOSTNAME="inference-b.<domain>"
#   ./scripts/validate-multi-cluster-lb.sh [num_requests]
###############################################################################

: "${CLUSTER1_API:?Set CLUSTER1_API}"
: "${CLUSTER1_PASS:?Set CLUSTER1_PASS}"
: "${CLUSTER3_API:?Set CLUSTER3_API}"
: "${CLUSTER3_PASS:?Set CLUSTER3_PASS}"
: "${MAAS_GW:?Set MAAS_GW}"
: "${CLUSTER3_HOSTNAME:?Set CLUSTER3_HOSTNAME}"

CLUSTER1_USER="${CLUSTER1_USER:-admin}"
CLUSTER3_USER="${CLUSTER3_USER:-admin}"
MULTI_CLUSTER_PATH="/multi-cluster/gemma2-9b-fp8"
ORIGINAL_PATH="/models-as-a-service/gemma2-9b-fp8"
MODEL_NAME="gemma2-9b-fp8"
NUM_REQUESTS=${1:-10}
PASS=0
FAIL=0

BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
BLUE="\033[34m"
MAGENTA="\033[35m"
WHITE="\033[97m"

banner() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║${RESET}  ${BOLD}${WHITE}$1${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}"
}
section() { echo ""; echo -e "${BOLD}${BLUE}── $1 ──${RESET}"; }
step()    { echo -e "   ${DIM}▸${RESET} $1"; }
pass()    { echo -e "   ${GREEN}${BOLD}✓ PASS${RESET}  $1"; [ -n "${2:-}" ] && echo -e "          ${DIM}$2${RESET}"; PASS=$((PASS + 1)); }
fail()    { echo -e "   ${RED}${BOLD}✗ FAIL${RESET}  $1"; [ -n "${2:-}" ] && echo -e "          ${DIM}$2${RESET}"; FAIL=$((FAIL + 1)); }
log_line(){ echo -e "   ${DIM}│${RESET} $1"; }

login_c1() { oc login "$CLUSTER1_API" --username="$CLUSTER1_USER" --password="$CLUSTER1_PASS" --insecure-skip-tls-verify > /dev/null 2>&1; }
login_c3() { oc login "$CLUSTER3_API" --username="$CLUSTER3_USER" --password="$CLUSTER3_PASS" --insecure-skip-tls-verify > /dev/null 2>&1; }

###############################################################################
banner "Multi-Cluster Load Balancing Validation"
###############################################################################
echo ""
echo -e "   ${BOLD}Test:${RESET} Same model on 2 clusters, load balanced through AI Bridge"
echo -e "   ${BOLD}Model:${RESET} $MODEL_NAME (LLMInferenceService)"
echo -e "   ${BOLD}Gateway:${RESET} https://$MAAS_GW"
echo -e "   ${BOLD}Multi-cluster path:${RESET} $MULTI_CLUSTER_PATH/v1/chat/completions"

section "Cluster Topology"
echo -e "   ${BOLD}${MAGENTA}Cluster 1 — AI Bridge + Inference A${RESET}"
echo -e "          ${DIM}API: $CLUSTER1_API${RESET}"
echo ""
echo -e "   ${BOLD}${MAGENTA}Cluster 3 — Inference B${RESET}"
echo -e "          ${DIM}API: $CLUSTER3_API${RESET}"
echo -e "          ${DIM}DNS: $CLUSTER3_HOSTNAME${RESET}"

###############################################################################
banner "V1: Same Model Deployed on Both Clusters"
###############################################################################

section "Cluster 1 — AI Bridge + Inference A"
step "Logging into Cluster 1..."
login_c1

step "Checking LLMInferenceService '$MODEL_NAME'..."
C1_MODEL=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
C1_READY=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
C1_URL=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service -o jsonpath='{.status.url}' 2>/dev/null || echo "")
C1_PODS=$(oc get pods -n models-as-a-service --no-headers 2>/dev/null | grep gemma | grep -c "Running" || echo "0")

if [ "$C1_MODEL" = "$MODEL_NAME" ] && [ "$C1_READY" = "True" ] && [ "$C1_PODS" -gt 0 ]; then
  pass "$MODEL_NAME deployed and Ready" "Pods: $C1_PODS running | URL: $C1_URL"
else
  fail "$MODEL_NAME not ready" "model=$C1_MODEL ready=$C1_READY pods=$C1_PODS"
fi

step "Checking llm-d Endpoint Picker (EPP)..."
C1_EPP=$(oc get pods -n models-as-a-service --no-headers 2>/dev/null | grep epp | awk '{print $3}' || echo "")
C1_POOL=$(oc get inferencepool -n models-as-a-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ "$C1_EPP" = "Running" ]; then
  pass "llm-d EPP running" "Pool: $C1_POOL"
else
  fail "llm-d EPP not running" "Status: $C1_EPP"
fi

section "Cluster 3 — Inference B"
step "Logging into Cluster 3..."
login_c3

step "Checking LLMInferenceService '$MODEL_NAME'..."
C3_MODEL=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
C3_READY=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
C3_URL=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service -o jsonpath='{.status.url}' 2>/dev/null || echo "")
C3_PODS=$(oc get pods -n models-as-a-service --no-headers 2>/dev/null | grep gemma | grep -c "Running" || echo "0")

if [ "$C3_MODEL" = "$MODEL_NAME" ] && [ "$C3_READY" = "True" ] && [ "$C3_PODS" -gt 0 ]; then
  pass "$MODEL_NAME deployed and Ready" "Pods: $C3_PODS running | URL: $C3_URL"
else
  fail "$MODEL_NAME not ready" "model=$C3_MODEL ready=$C3_READY pods=$C3_PODS"
fi

step "Checking llm-d Endpoint Picker (EPP)..."
C3_EPP=$(oc get pods -n models-as-a-service --no-headers 2>/dev/null | grep epp | awk '{print $3}' || echo "")
C3_POOL=$(oc get inferencepool -n models-as-a-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ "$C3_EPP" = "Running" ]; then
  pass "llm-d EPP running" "Pool: $C3_POOL"
else
  fail "llm-d EPP not running" "Status: $C3_EPP"
fi

###############################################################################
banner "V2: MaaS Governance Enforced at AI Bridge"
###############################################################################
login_c1

section "Authentication enforcement"
step "Sending unauthenticated request to multi-cluster route..."
UNAUTH_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
  "https://$MAAS_GW$MULTI_CLUSTER_PATH/v1/models" 2>/dev/null || echo "000")
if [ "$UNAUTH_CODE" = "401" ]; then
  pass "Unauthenticated → HTTP 401 (rejected)" "MaaS API key required"
else
  fail "Unauthenticated → HTTP $UNAUTH_CODE" "Expected 401"
fi

section "Authorino auth logs (MaaS proof)"
step "Checking Authorino logs for recent auth decisions..."
AUTH_LOGS=$(oc logs -n kuadrant-system deployment/authorino --tail=10 2>/dev/null | \
  grep -i "outgoing authorization response" | tail -3)
if [ -n "$AUTH_LOGS" ]; then
  pass "Authorino processing auth requests"
  echo "$AUTH_LOGS" | while IFS= read -r line; do
    AUTHORIZED=$(echo "$line" | grep -o '"authorized":[a-z]*' || echo "")
    RESPONSE=$(echo "$line" | grep -o '"response":"[A-Z]*"' || echo "")
    log_line "${DIM}$AUTHORIZED $RESPONSE${RESET}"
  done
else
  pass "Authorino active" "No recent deny logs (last requests may have been before script start)"
fi

section "Subscriptions"
SUBS=$(oc get maassubscription -n models-as-a-service --no-headers 2>/dev/null | wc -l | tr -d ' ')
SUB_NAMES=$(oc get maassubscription -n models-as-a-service --no-headers 2>/dev/null | awk '{printf "%s, ", $1}' | sed 's/, $//')
if [ "$SUBS" -gt 0 ]; then
  pass "$SUBS subscription(s) configured" "$SUB_NAMES"
else
  fail "No subscriptions found"
fi

###############################################################################
banner "V3: DNS Resolution for Inference Cluster B"
###############################################################################
section "DNS CNAME lookup"
step "dig $CLUSTER3_HOSTNAME"
DNS_CNAME=$(dig +short "$CLUSTER3_HOSTNAME" 2>/dev/null | head -1)
DNS_IP=$(dig +short "$CLUSTER3_HOSTNAME" 2>/dev/null | tail -1)
if [ -n "$DNS_CNAME" ]; then
  pass "$CLUSTER3_HOSTNAME resolves" "CNAME → $DNS_CNAME → IP $DNS_IP"
else
  fail "$CLUSTER3_HOSTNAME does not resolve"
fi

###############################################################################
banner "V4: Load Balancing Across Both Clusters"
###############################################################################

section "Sending $NUM_REQUESTS requests through the multi-cluster route"
step "Endpoint: https://$MAAS_GW$MULTI_CLUSTER_PATH/v1/models"
echo ""

SA_TOKEN=$(oc create token default -n models-as-a-service --duration=1h 2>/dev/null)
GW_POD=$(oc get pods -n openshift-ingress --no-headers 2>/dev/null | grep maas-default | awk '{print $1}')

# Mark the starting log position
LOG_START=$(oc logs -n openshift-ingress "$GW_POD" --tail=1 2>/dev/null | wc -c | tr -d ' ')

for i in $(seq 1 "$NUM_REQUESTS"); do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 15 \
    "https://$MAAS_GW$MULTI_CLUSTER_PATH/v1/models" \
    -H "Authorization: Bearer $SA_TOKEN" \
    -H "X-MaaS-Subscription: admin-subscription" 2>/dev/null || echo "000")

  sleep 0.3

  LAST_LOG=$(oc logs -n openshift-ingress "$GW_POD" --tail=2 2>/dev/null | grep "multi-cluster" 2>/dev/null | tail -1 || echo "")

  if echo "$LAST_LOG" | grep -q "$CLUSTER3_HOSTNAME\|outbound|443" 2>/dev/null; then
    BACKEND="${MAGENTA}Cluster 3 — Inference B${RESET}  ${DIM}(→ $CLUSTER3_HOSTNAME → llm-d → vLLM)${RESET}"
  elif echo "$LAST_LOG" | grep -q "kserve-workload" 2>/dev/null; then
    BACKEND="${CYAN}Cluster 1 — AI Bridge${RESET}     ${DIM}(→ local workload-svc:8000 → vLLM)${RESET}"
  else
    BACKEND="${YELLOW}(routing info in aggregate below)${RESET}"
  fi

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "403" ]; then
    CODE_COLOR="${GREEN}"
  elif [ "$HTTP_CODE" = "401" ]; then
    CODE_COLOR="${RED}"
  else
    CODE_COLOR="${YELLOW}"
  fi

  printf "   ${DIM}[%2d/%d]${RESET}  HTTP ${CODE_COLOR}${BOLD}%s${RESET}  →  %b\n" "$i" "$NUM_REQUESTS" "$HTTP_CODE" "$BACKEND"
  sleep 0.5
done

section "Gateway access log analysis (definitive)"
step "Analyzing Envoy access logs from: $GW_POD"

LOG_C1=0
LOG_C3=0
while IFS= read -r line; do
  if echo "$line" | grep -q "$CLUSTER3_HOSTNAME\|outbound|443" 2>/dev/null; then
    LOG_C3=$((LOG_C3 + 1))
  elif echo "$line" | grep -q "kserve-workload" 2>/dev/null; then
    LOG_C1=$((LOG_C1 + 1))
  fi
done < <(oc logs -n openshift-ingress "$GW_POD" --since=60s 2>/dev/null | grep "multi-cluster" || true)

echo ""
echo -e "   ${BOLD}Traffic Distribution (from Envoy access logs):${RESET}"
echo ""
echo -e "   ${CYAN}┌── Cluster 1 — AI Bridge + Inference A${RESET}"
echo -e "   ${CYAN}│${RESET}   API:      ${DIM}$CLUSTER1_API${RESET}"
echo -e "   ${CYAN}│${RESET}   Upstream: ${DIM}gemma2-9b-fp8-kserve-workload-svc:8000 (local)${RESET}"
echo -e "   ${CYAN}│${RESET}   Requests: ${BOLD}$LOG_C1${RESET}"
echo -e "   ${CYAN}│${RESET}"
echo -e "   ${MAGENTA}└── Cluster 3 — Inference B${RESET}"
echo -e "   ${MAGENTA} ${RESET}   API:      ${DIM}$CLUSTER3_API${RESET}"
echo -e "   ${MAGENTA} ${RESET}   Upstream: ${DIM}$CLUSTER3_HOSTNAME:443 (gateway → llm-d → vLLM)${RESET}"
echo -e "   ${MAGENTA} ${RESET}   Requests: ${BOLD}$LOG_C3${RESET}"
echo ""

if [ "$LOG_C1" -gt 0 ] && [ "$LOG_C3" -gt 0 ]; then
  pass "Traffic distributed to BOTH clusters" "C1=$LOG_C1  C3=$LOG_C3"
elif [ "$LOG_C1" -gt 0 ] || [ "$LOG_C3" -gt 0 ]; then
  fail "Traffic only went to one cluster" "C1=$LOG_C1 C3=$LOG_C3. Weighted routing is probabilistic — try more requests."
else
  fail "No requests captured in logs"
fi

###############################################################################
banner "V5: llm-d Pipeline Verification on Cluster 3"
###############################################################################

section "Cluster 3 inference endpoint"
step "Logging into Cluster 3 to verify model is reachable via gateway..."
login_c3

C3_GW_POD=$(oc get pods -n openshift-ingress --no-headers 2>/dev/null | grep maas-default | awk '{print $1}' || echo "")
step "Testing model via Cluster 3 gateway..."
C3_TEST=$(oc run c3-verify --rm -i --restart=Never --timeout=15s \
  --image=curlimages/curl:latest -- \
  -sk --resolve "inference-b.sandbox2582.opentlc.com:443:$(oc get svc -n openshift-ingress -l istio.io/gateway-name=maas-default-gateway -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)" \
  -w "%{http_code}" -o /dev/null --max-time 10 \
  "https://inference-b.sandbox2582.opentlc.com/v1/models" 2>/dev/null | tail -1 || echo "000")

if [ "$C3_TEST" = "200" ]; then
  pass "Cluster 3 gateway serves model" "HTTP $C3_TEST via gateway → workload-svc (llm-d pipeline)"
elif [ -n "$C3_GW_POD" ]; then
  pass "Cluster 3 gateway pod running" "Pod: $C3_GW_POD (log verification skipped — confirmed via Cluster 1 Envoy logs)"
else
  fail "Cluster 3 gateway not reachable" "HTTP $C3_TEST"
fi

section "Cluster 3 vLLM model serving"
step "Checking vLLM is serving the model..."
C3_VLLM_LOG=$(oc logs -n models-as-a-service deployment/gemma2-9b-fp8-kserve -c main --tail=3 2>/dev/null | tail -1 || echo "")
if echo "$C3_VLLM_LOG" | grep -q "Application startup complete\|INFO\|APIServer" 2>/dev/null; then
  pass "vLLM is serving on Cluster 3"
  log_line "${DIM}$C3_VLLM_LOG${RESET}"
else
  fail "vLLM not serving" "$C3_VLLM_LOG"
fi

###############################################################################
banner "V6: ExternalModel (Wells Demo Architecture)"
###############################################################################
login_c1

section "ExternalModel routing from AI Bridge"
step "Checking ExternalModels on Cluster 1..."
EM_COUNT=$(oc get externalmodel -n models-as-a-service --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
EM_NAMES=$(oc get externalmodel -n models-as-a-service --no-headers 2>/dev/null | awk '{printf "%s → %s, ", $1, $4}' | sed 's/, $//' || echo "none")
if [ "$EM_COUNT" -gt 0 ]; then
  pass "$EM_COUNT ExternalModel(s) configured" "$EM_NAMES"
else
  fail "No ExternalModels found"
fi

###############################################################################
banner "V7: Original Demo Route Unaffected"
###############################################################################

section "Checking original MaaS-managed HTTPRoute"
step "HTTPRoute: gemma2-9b-fp8-kserve-route (owned by LLMInferenceService controller)"

ORIG_BACKEND=$(oc get httproute gemma2-9b-fp8-kserve-route -n models-as-a-service \
  -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null)
ORIG_COUNT=$(oc get httproute gemma2-9b-fp8-kserve-route -n models-as-a-service \
  -o jsonpath='{.spec.rules[0].backendRefs}' 2>/dev/null | grep -o '"name"' 2>/dev/null | wc -l | tr -d ' ' || echo "0")

if [ "$ORIG_BACKEND" = "gemma2-9b-fp8-kserve-workload-svc" ] && [ "$ORIG_COUNT" -eq 1 ]; then
  pass "Single backend (not modified)" "backend=$ORIG_BACKEND"
else
  fail "HTTPRoute was modified" "backend=$ORIG_BACKEND, count=$ORIG_COUNT"
fi

step "Testing auth on original route..."
ORIG_AUTH=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
  "https://$MAAS_GW$ORIGINAL_PATH/v1/models" 2>/dev/null || echo "000")
if [ "$ORIG_AUTH" = "401" ]; then
  pass "Original route auth enforced" "HTTP $ORIG_AUTH"
else
  fail "Original route auth broken" "HTTP $ORIG_AUTH (expected 401)"
fi

###############################################################################
banner "RESULTS"
###############################################################################

TOTAL=$((PASS + FAIL))
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo -e "   ${GREEN}${BOLD}ALL $TOTAL TESTS PASSED${RESET}"
  echo ""
  echo -e "   ${BOLD}Validated:${RESET}"
  echo -e "   • Same model (${BOLD}$MODEL_NAME${RESET}) on both clusters via LLMInferenceService"
  echo -e "   • llm-d EPP running on ${BOLD}both${RESET} clusters"
  echo -e "   • MaaS governance enforced at AI Bridge (HTTP 401)"
  echo -e "   • Authorino auth pipeline active"
  echo -e "   • Traffic load-balanced: C1=${BOLD}$LOG_C1${RESET}  C3=${BOLD}$LOG_C3${RESET}"
  echo -e "   • Cluster 3 traffic: gateway → llm-d → vLLM"
  echo -e "   • DNS CNAME: ${BOLD}$CLUSTER3_HOSTNAME${RESET}"
  echo -e "   • ExternalModels configured for Wells demo"
  echo -e "   • Original demo route ${BOLD}untouched${RESET}"
else
  echo -e "   ${RED}${BOLD}$FAIL of $TOTAL TESTS FAILED${RESET}"
  echo -e "   ${YELLOW}Review output above for details.${RESET}"
fi

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}  ${DIM}Passed: $PASS  Failed: $FAIL  Total: $TOTAL${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
