#!/bin/bash
set -euo pipefail

###############################################################################
# Multi-Cluster Load Balancing Validation Script
#
# Validates: "Is there a way to have the same model deployed in 2 clusters
# and load balance between the two?"
#
#   AI Bridge Cluster    → Cluster 1 (sandbox1011) — governance + inference A
#   Inference Cluster B  → Cluster 3 (sandbox2582) — inference B
#
# Architecture:
#   Client → AI Bridge MaaS Gateway → Auth + Rate Limit → Weighted HTTPRoute
#     ├── 50% → Cluster 1 vLLM (local, port 8000)
#     └── 50% → Cluster 3 Gateway → llm-d → vLLM (inference-b.sandbox2582.opentlc.com)
###############################################################################

# Cluster details
CLUSTER1_NAME="Cluster 1 — AI Bridge + Inference A"
CLUSTER1_API="https://api.cluster-6crhb.6crhb.sandbox1011.opentlc.com:6443"
CLUSTER1_CONSOLE="https://console-openshift-console.apps.cluster-6crhb.6crhb.sandbox1011.opentlc.com"
CLUSTER1_USER="admin"
CLUSTER1_PASS="MzA0NjE1NjM2"

CLUSTER3_NAME="Cluster 3 — Inference B"
CLUSTER3_API="https://api.cluster-bf44z.bf44z.sandbox2582.opentlc.com:6443"
CLUSTER3_CONSOLE="https://console-openshift-console.apps.cluster-bf44z.bf44z.sandbox2582.opentlc.com"
CLUSTER3_USER="admin"
CLUSTER3_PASS="MTU1Mzg0OTk2"
CLUSTER3_HOSTNAME="inference-b.sandbox2582.opentlc.com"

MAAS_GW="ae7a90237753943bb8619a15f4c4ff3e-47983113.us-east-2.elb.amazonaws.com"
MULTI_CLUSTER_PATH="/multi-cluster/gemma2-9b-fp8"
ORIGINAL_PATH="/models-as-a-service/gemma2-9b-fp8"
MODEL_NAME="gemma2-9b-fp8"
NUM_REQUESTS=${1:-10}

PASS=0
FAIL=0

# Colors and formatting
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

section() {
  echo ""
  echo -e "${BOLD}${BLUE}── $1 ──${RESET}"
}

step() {
  echo -e "   ${DIM}▸${RESET} $1"
}

pass() {
  local name="$1" detail="${2:-}"
  echo -e "   ${GREEN}${BOLD}✓ PASS${RESET}  $name"
  [ -n "$detail" ] && echo -e "          ${DIM}$detail${RESET}"
  PASS=$((PASS + 1))
}

fail() {
  local name="$1" detail="${2:-}"
  echo -e "   ${RED}${BOLD}✗ FAIL${RESET}  $name"
  [ -n "$detail" ] && echo -e "          ${DIM}$detail${RESET}"
  FAIL=$((FAIL + 1))
}

info() {
  echo -e "          ${DIM}$1${RESET}"
}

cluster_info() {
  local name="$1" api="$2" console="$3"
  echo -e "   ${BOLD}${MAGENTA}$name${RESET}"
  echo -e "          ${DIM}API:     $api${RESET}"
  echo -e "          ${DIM}Console: $console${RESET}"
}

###############################################################################
banner "Multi-Cluster Load Balancing Validation"
###############################################################################

echo ""
echo -e "   ${BOLD}Test:${RESET} Same model on 2 clusters, load balanced through AI Bridge"
echo -e "   ${BOLD}Model:${RESET} $MODEL_NAME (LLMInferenceService)"
echo -e "   ${BOLD}Gateway:${RESET} https://$MAAS_GW"
echo -e "   ${BOLD}Multi-cluster path:${RESET} $MULTI_CLUSTER_PATH/v1/chat/completions"
echo ""
section "Cluster Topology"
cluster_info "$CLUSTER1_NAME" "$CLUSTER1_API" "$CLUSTER1_CONSOLE"
echo ""
cluster_info "$CLUSTER3_NAME" "$CLUSTER3_API" "$CLUSTER3_CONSOLE"
echo -e "          ${DIM}DNS:     $CLUSTER3_HOSTNAME${RESET}"

###############################################################################
banner "V1: Same Model Deployed on Both Clusters"
###############################################################################

section "$CLUSTER1_NAME"
step "Logging into $CLUSTER1_API..."
oc login "$CLUSTER1_API" --username="$CLUSTER1_USER" --password="$CLUSTER1_PASS" \
  --insecure-skip-tls-verify > /dev/null 2>&1

step "Checking LLMInferenceService '$MODEL_NAME'..."
C1_MODEL=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
C1_READY=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
C1_URL=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service \
  -o jsonpath='{.status.url}' 2>/dev/null || echo "")
C1_PODS=$(oc get pods -n models-as-a-service --no-headers 2>/dev/null | grep gemma | grep "Running" | wc -l | tr -d ' ')

if [ "$C1_MODEL" = "$MODEL_NAME" ] && [ "$C1_READY" = "True" ] && [ "$C1_PODS" -gt 0 ]; then
  pass "$MODEL_NAME deployed and Ready" "Pods: $C1_PODS running | URL: $C1_URL"
else
  fail "$MODEL_NAME not ready" "model=$C1_MODEL ready=$C1_READY pods=$C1_PODS"
fi

section "$CLUSTER3_NAME"
step "Logging into $CLUSTER3_API..."
oc login "$CLUSTER3_API" --username="$CLUSTER3_USER" --password="$CLUSTER3_PASS" \
  --insecure-skip-tls-verify > /dev/null 2>&1

step "Checking LLMInferenceService '$MODEL_NAME'..."
C3_MODEL=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
C3_READY=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
C3_URL=$(oc get llminferenceservice "$MODEL_NAME" -n models-as-a-service \
  -o jsonpath='{.status.url}' 2>/dev/null || echo "")
C3_PODS=$(oc get pods -n models-as-a-service --no-headers 2>/dev/null | grep gemma | grep "Running" | wc -l | tr -d ' ')

if [ "$C3_MODEL" = "$MODEL_NAME" ] && [ "$C3_READY" = "True" ] && [ "$C3_PODS" -gt 0 ]; then
  pass "$MODEL_NAME deployed and Ready" "Pods: $C3_PODS running | URL: $C3_URL"
else
  fail "$MODEL_NAME not ready" "model=$C3_MODEL ready=$C3_READY pods=$C3_PODS"
fi

###############################################################################
banner "V2: MaaS Governance Enforced at AI Bridge"
###############################################################################

oc login "$CLUSTER1_API" --username="$CLUSTER1_USER" --password="$CLUSTER1_PASS" \
  --insecure-skip-tls-verify > /dev/null 2>&1

section "Authentication enforcement"
step "Sending unauthenticated request to multi-cluster route..."
step "curl -sk https://$MAAS_GW$MULTI_CLUSTER_PATH/v1/models"
UNAUTH_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
  "https://$MAAS_GW$MULTI_CLUSTER_PATH/v1/models" 2>/dev/null || echo "000")

if [ "$UNAUTH_CODE" = "401" ]; then
  pass "Unauthenticated → HTTP 401 (rejected)" "MaaS API key required"
else
  fail "Unauthenticated → HTTP $UNAUTH_CODE" "Expected 401"
fi

step "Sending unauthenticated request to original MaaS route..."
step "curl -sk https://$MAAS_GW$ORIGINAL_PATH/v1/models"
ORIG_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
  "https://$MAAS_GW$ORIGINAL_PATH/v1/models" 2>/dev/null || echo "000")

if [ "$ORIG_CODE" = "401" ]; then
  pass "Original route also returns HTTP 401" "Same auth pipeline"
else
  fail "Original route returned HTTP $ORIG_CODE" "Expected 401"
fi

section "Subscriptions"
step "Listing MaaS subscriptions on AI Bridge..."
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
  pass "$CLUSTER3_HOSTNAME resolves" "CNAME → $DNS_CNAME"
  info "IP → $DNS_IP"
else
  fail "$CLUSTER3_HOSTNAME does not resolve" "DNS CNAME missing in Route 53"
fi

###############################################################################
banner "V4: Load Balancing Across Both Clusters"
###############################################################################

section "Sending $NUM_REQUESTS requests through the multi-cluster route"
step "Endpoint: https://$MAAS_GW$MULTI_CLUSTER_PATH/v1/models"
step "Auth: Kubernetes ServiceAccount token + X-MaaS-Subscription header"
echo ""

SA_TOKEN=$(oc create token default -n models-as-a-service --duration=1h 2>/dev/null)
GW_POD=$(oc get pods -n openshift-ingress --no-headers 2>/dev/null | grep maas-default | awk '{print $1}')

C1_HIT=0
C3_HIT=0
OTHER_HIT=0

for i in $(seq 1 "$NUM_REQUESTS"); do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 15 \
    "https://$MAAS_GW$MULTI_CLUSTER_PATH/v1/models" \
    -H "Authorization: Bearer $SA_TOKEN" \
    -H "X-MaaS-Subscription: admin-subscription" 2>/dev/null || echo "000")

  sleep 0.5

  LAST_LOG=$(oc logs -n openshift-ingress "$GW_POD" --tail=1 2>/dev/null || echo "")
  if echo "$LAST_LOG" | grep -q "inference-b.sandbox2582"; then
    BACKEND="${MAGENTA}$CLUSTER3_NAME${RESET}"
    BACKEND_SHORT="C3"
    C3_HIT=$((C3_HIT + 1))
  elif echo "$LAST_LOG" | grep -q "kserve-workload"; then
    BACKEND="${CYAN}$CLUSTER1_NAME${RESET}"
    BACKEND_SHORT="C1"
    C1_HIT=$((C1_HIT + 1))
  else
    BACKEND="${YELLOW}(log not captured)${RESET}"
    BACKEND_SHORT="??"
    OTHER_HIT=$((OTHER_HIT + 1))
  fi

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "403" ]; then
    STATUS_COLOR="${GREEN}"
  else
    STATUS_COLOR="${RED}"
  fi

  printf "   ${DIM}[%2d/%d]${RESET}  HTTP ${STATUS_COLOR}${BOLD}%s${RESET}  →  %b\n" \
    "$i" "$NUM_REQUESTS" "$HTTP_CODE" "$BACKEND"

  sleep 0.5
done

section "Gateway access log analysis"
step "Reading Envoy access logs from gateway pod: $GW_POD"

LOG_C1=0
LOG_C3=0
while IFS= read -r line; do
  if echo "$line" | grep -q "inference-b.sandbox2582"; then
    LOG_C3=$((LOG_C3 + 1))
  elif echo "$line" | grep -q "kserve-workload"; then
    LOG_C1=$((LOG_C1 + 1))
  fi
done < <(oc logs -n openshift-ingress "$GW_POD" --since=30s 2>/dev/null | grep "multi-cluster")

echo ""
echo -e "   ${BOLD}Traffic Distribution:${RESET}"
echo -e "   ${CYAN}├── $CLUSTER1_NAME${RESET}"
echo -e "   ${CYAN}│   ${RESET}  Upstream: ${DIM}gemma2-9b-fp8-kserve-workload-svc:8000 (local)${RESET}"
echo -e "   ${CYAN}│   ${RESET}  Requests: ${BOLD}$LOG_C1${RESET}"
echo -e "   ${MAGENTA}└── $CLUSTER3_NAME${RESET}"
echo -e "   ${MAGENTA}    ${RESET}  Upstream: ${DIM}$CLUSTER3_HOSTNAME:443 (via gateway → llm-d → vLLM)${RESET}"
echo -e "   ${MAGENTA}    ${RESET}  Requests: ${BOLD}$LOG_C3${RESET}"
echo ""

if [ "$LOG_C1" -gt 0 ] && [ "$LOG_C3" -gt 0 ]; then
  pass "Traffic distributed to BOTH clusters" "C1=$LOG_C1  C3=$LOG_C3"
elif [ "$LOG_C1" -gt 0 ] || [ "$LOG_C3" -gt 0 ]; then
  TOTAL=$((LOG_C1 + LOG_C3))
  fail "Traffic only went to one cluster" "C1=$LOG_C1 C3=$LOG_C3 (total=$TOTAL). Weighted routing is probabilistic — run again with more requests."
else
  fail "No requests captured in logs" "Gateway logs may have rotated"
fi

###############################################################################
banner "V5: Original Demo Route Unaffected"
###############################################################################

section "Checking original MaaS-managed HTTPRoute"
step "HTTPRoute: gemma2-9b-fp8-kserve-route (owned by LLMInferenceService controller)"

ORIG_BACKEND=$(oc get httproute gemma2-9b-fp8-kserve-route -n models-as-a-service \
  -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null)
ORIG_COUNT=$(oc get httproute gemma2-9b-fp8-kserve-route -n models-as-a-service \
  -o jsonpath='{.spec.rules[0].backendRefs}' 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' ')

if [ "$ORIG_BACKEND" = "gemma2-9b-fp8-kserve-workload-svc" ] && [ "$ORIG_COUNT" -eq 1 ]; then
  pass "Single backend (not modified)" "backend=$ORIG_BACKEND, count=$ORIG_COUNT"
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
  echo -e "   ${BOLD}Summary:${RESET}"
  echo -e "   • Same model (${BOLD}$MODEL_NAME${RESET}) running on both clusters via LLMInferenceService"
  echo -e "   • MaaS governance enforced at AI Bridge (HTTP 401 for unauthenticated)"
  echo -e "   • Traffic load-balanced: C1=${BOLD}$LOG_C1${RESET}  C3=${BOLD}$LOG_C3${RESET} requests"
  echo -e "   • Cluster 3 reached via gateway at ${BOLD}$CLUSTER3_HOSTNAME${RESET}"
  echo -e "   • Original Wells Fargo demo route ${BOLD}untouched${RESET}"
else
  echo -e "   ${RED}${BOLD}$FAIL of $TOTAL TESTS FAILED${RESET}"
  echo -e "   ${YELLOW}Review the output above for details.${RESET}"
fi

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}  ${DIM}Passed: $PASS  Failed: $FAIL  Total: $TOTAL${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
