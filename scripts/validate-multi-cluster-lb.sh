#!/bin/bash
set -euo pipefail

###############################################################################
# Multi-Cluster Load Balancing Validation Script
#
# Validates that the same model (gemma2-9b-fp8) is deployed on two clusters
# and traffic is load-balanced between them through the AI Bridge MaaS gateway.
#
# Architecture:
#   Client → AI Bridge (Cluster 1) → MaaS Auth → Weighted HTTPRoute
#     ├── 50% → Cluster 1 vLLM (local)
#     └── 50% → Cluster 3 vLLM (via gateway at inference-b.sandbox2582.opentlc.com)
###############################################################################

CLUSTER1_API="https://api.cluster-6crhb.6crhb.sandbox1011.opentlc.com:6443"
CLUSTER3_API="https://api.cluster-bf44z.bf44z.sandbox2582.opentlc.com:6443"
CLUSTER1_USER="admin"
CLUSTER1_PASS="MzA0NjE1NjM2"
CLUSTER3_USER="admin"
CLUSTER3_PASS="MTU1Mzg0OTk2"
MAAS_GW="ae7a90237753943bb8619a15f4c4ff3e-47983113.us-east-2.elb.amazonaws.com"
CLUSTER3_HOSTNAME="inference-b.sandbox2582.opentlc.com"
NUM_REQUESTS=10

PASS=0
FAIL=0

print_header() {
  echo ""
  echo "================================================================"
  echo "  $1"
  echo "================================================================"
}

print_test() {
  local name="$1" result="$2" detail="$3"
  if [ "$result" = "PASS" ]; then
    echo "  [PASS] $name"
    [ -n "$detail" ] && echo "         $detail"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $name"
    [ -n "$detail" ] && echo "         $detail"
    FAIL=$((FAIL + 1))
  fi
}

###############################################################################
print_header "V1: Same Model on Both Clusters"
###############################################################################

echo "  Checking Cluster 1 (AI Bridge + Inference A)..."
oc login "$CLUSTER1_API" --username="$CLUSTER1_USER" --password="$CLUSTER1_PASS" \
  --insecure-skip-tls-verify > /dev/null 2>&1

C1_MODEL=$(oc get llminferenceservice gemma2-9b-fp8 -n models-as-a-service \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
C1_READY=$(oc get llminferenceservice gemma2-9b-fp8 -n models-as-a-service \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
C1_PODS=$(oc get pods -n models-as-a-service --no-headers 2>/dev/null | grep gemma | grep "Running" | wc -l | tr -d ' ')

if [ "$C1_MODEL" = "gemma2-9b-fp8" ] && [ "$C1_READY" = "True" ] && [ "$C1_PODS" -gt 0 ]; then
  print_test "Cluster 1: gemma2-9b-fp8 LLMInferenceService" "PASS" "Ready=True, $C1_PODS pod(s) running"
else
  print_test "Cluster 1: gemma2-9b-fp8 LLMInferenceService" "FAIL" "model=$C1_MODEL ready=$C1_READY pods=$C1_PODS"
fi

echo "  Checking Cluster 3 (Inference B)..."
oc login "$CLUSTER3_API" --username="$CLUSTER3_USER" --password="$CLUSTER3_PASS" \
  --insecure-skip-tls-verify > /dev/null 2>&1

C3_MODEL=$(oc get llminferenceservice gemma2-9b-fp8 -n models-as-a-service \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
C3_READY=$(oc get llminferenceservice gemma2-9b-fp8 -n models-as-a-service \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
C3_PODS=$(oc get pods -n models-as-a-service --no-headers 2>/dev/null | grep gemma | grep "Running" | wc -l | tr -d ' ')

if [ "$C3_MODEL" = "gemma2-9b-fp8" ] && [ "$C3_READY" = "True" ] && [ "$C3_PODS" -gt 0 ]; then
  print_test "Cluster 3: gemma2-9b-fp8 LLMInferenceService" "PASS" "Ready=True, $C3_PODS pod(s) running"
else
  print_test "Cluster 3: gemma2-9b-fp8 LLMInferenceService" "FAIL" "model=$C3_MODEL ready=$C3_READY pods=$C3_PODS"
fi

###############################################################################
print_header "V2: MaaS Governance on AI Bridge"
###############################################################################

oc login "$CLUSTER1_API" --username="$CLUSTER1_USER" --password="$CLUSTER1_PASS" \
  --insecure-skip-tls-verify > /dev/null 2>&1

echo "  Testing unauthenticated request to multi-cluster route..."
UNAUTH_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
  "https://$MAAS_GW/multi-cluster/gemma2-9b-fp8/v1/models" 2>/dev/null || echo "000")

if [ "$UNAUTH_CODE" = "401" ]; then
  print_test "Unauthenticated → 401" "PASS" "HTTP $UNAUTH_CODE"
else
  print_test "Unauthenticated → 401" "FAIL" "HTTP $UNAUTH_CODE (expected 401)"
fi

echo "  Testing unauthenticated on original MaaS route..."
ORIG_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
  "https://$MAAS_GW/models-as-a-service/gemma2-9b-fp8/v1/models" 2>/dev/null || echo "000")

if [ "$ORIG_CODE" = "401" ]; then
  print_test "Original route also protected" "PASS" "HTTP $ORIG_CODE"
else
  print_test "Original route also protected" "FAIL" "HTTP $ORIG_CODE (expected 401)"
fi

SUBS=$(oc get maassubscription -n models-as-a-service --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$SUBS" -gt 0 ]; then
  print_test "MaaS subscriptions exist" "PASS" "$SUBS subscription(s)"
else
  print_test "MaaS subscriptions exist" "FAIL" "0 subscriptions"
fi

###############################################################################
print_header "V3: DNS Resolution for Cluster 3"
###############################################################################

echo "  Resolving $CLUSTER3_HOSTNAME..."
DNS_RESULT=$(dig +short "$CLUSTER3_HOSTNAME" 2>/dev/null | head -1)
if [ -n "$DNS_RESULT" ]; then
  print_test "DNS CNAME resolves" "PASS" "$CLUSTER3_HOSTNAME → $DNS_RESULT"
else
  print_test "DNS CNAME resolves" "FAIL" "No DNS response"
fi

###############################################################################
print_header "V4: Load Balancing Across Both Clusters"
###############################################################################

SA_TOKEN=$(oc create token default -n models-as-a-service --duration=1h 2>/dev/null)
GW_POD=$(oc get pods -n openshift-ingress --no-headers 2>/dev/null | grep maas-default | awk '{print $1}')

echo "  Sending $NUM_REQUESTS requests through multi-cluster route..."
echo "  (with 1 second delay between each)"
echo ""

for i in $(seq 1 $NUM_REQUESTS); do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 15 \
    "https://$MAAS_GW/multi-cluster/gemma2-9b-fp8/v1/models" \
    -H "Authorization: Bearer $SA_TOKEN" \
    -H "X-MaaS-Subscription: admin-subscription" 2>/dev/null || echo "000")

  LAST_LOG=$(oc logs -n openshift-ingress "$GW_POD" --tail=1 2>/dev/null | grep "multi-cluster" || echo "")
  if echo "$LAST_LOG" | grep -q "inference-b.sandbox2582\|ac3b790d"; then
    BACKEND="CLUSTER-3"
  elif echo "$LAST_LOG" | grep -q "kserve-workload"; then
    BACKEND="CLUSTER-1"
  else
    BACKEND="UNKNOWN"
  fi

  printf "    Request %2d: HTTP %-3s → %s\n" "$i" "$HTTP_CODE" "$BACKEND"
  sleep 1
done

echo ""
echo "  Analyzing gateway access logs..."

C1_COUNT=0
C3_COUNT=0
while IFS= read -r line; do
  if echo "$line" | grep -q "inference-b.sandbox2582\|ac3b790d"; then
    C3_COUNT=$((C3_COUNT + 1))
  elif echo "$line" | grep -q "kserve-workload"; then
    C1_COUNT=$((C1_COUNT + 1))
  fi
done < <(oc logs -n openshift-ingress "$GW_POD" --since=30s 2>/dev/null | grep "multi-cluster")

echo "    Cluster 1 (local vLLM):                    $C1_COUNT requests"
echo "    Cluster 3 ($CLUSTER3_HOSTNAME): $C3_COUNT requests"

if [ "$C1_COUNT" -gt 0 ] && [ "$C3_COUNT" -gt 0 ]; then
  print_test "Traffic distributed to BOTH clusters" "PASS" "C1=$C1_COUNT C3=$C3_COUNT"
elif [ "$C1_COUNT" -gt 0 ] || [ "$C3_COUNT" -gt 0 ]; then
  TOTAL=$((C1_COUNT + C3_COUNT))
  print_test "Traffic distributed to BOTH clusters" "FAIL" "Only one cluster hit (C1=$C1_COUNT C3=$C3_COUNT of $TOTAL total). Try running again — weighted routing is probabilistic."
else
  print_test "Traffic distributed to BOTH clusters" "FAIL" "No requests logged"
fi

###############################################################################
print_header "V5: Original Demo Unaffected"
###############################################################################

echo "  Verifying original MaaS route is untouched..."

ORIG_BACKENDS=$(oc get httproute gemma2-9b-fp8-kserve-route -n models-as-a-service \
  -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null)

if [ "$ORIG_BACKENDS" = "gemma2-9b-fp8-kserve-workload-svc" ]; then
  print_test "Original HTTPRoute single backend" "PASS" "backend=$ORIG_BACKENDS"
else
  print_test "Original HTTPRoute single backend" "FAIL" "backend=$ORIG_BACKENDS"
fi

ORIG_AUTH=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
  "https://$MAAS_GW/models-as-a-service/gemma2-9b-fp8/v1/models" 2>/dev/null || echo "000")

if [ "$ORIG_AUTH" = "401" ]; then
  print_test "Original route auth enforced" "PASS" "HTTP $ORIG_AUTH"
else
  print_test "Original route auth enforced" "FAIL" "HTTP $ORIG_AUTH"
fi

###############################################################################
print_header "RESULTS"
###############################################################################

TOTAL=$((PASS + FAIL))
echo ""
echo "  Passed: $PASS / $TOTAL"
echo "  Failed: $FAIL / $TOTAL"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "  ✓ ALL TESTS PASSED"
  echo ""
  echo "  Multi-cluster load balancing is working:"
  echo "    - Same model (gemma2-9b-fp8) on both clusters"
  echo "    - MaaS governance enforced at AI Bridge"
  echo "    - Traffic distributed across Cluster 1 and Cluster 3"
  echo "    - Cluster 3 accessed via gateway ($CLUSTER3_HOSTNAME)"
  echo "    - Original demo route untouched"
else
  echo "  ✗ SOME TESTS FAILED — review output above"
fi
echo ""
echo "================================================================"
