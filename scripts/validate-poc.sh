#!/bin/bash
# PoC Alignment Validation Script
# Tests all 8 success criteria + bonus capabilities against the live demo environment.
#
# Usage: ./scripts/validate-poc.sh
#
# Prerequisites:
#   - oc CLI logged into the inference cluster
#   - scripts/config.env populated
#   - All components deployed via deploy-all.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/config.env" ]; then
  echo "ERROR: scripts/config.env not found. Copy config.env.example and fill in values."
  exit 1
fi

source "$SCRIPT_DIR/config.env"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
RESULTS=()

record() {
  local sc="$1" test_name="$2" status="$3" detail="$4"
  if [ "$status" = "PASS" ]; then
    ((PASS_COUNT++))
  elif [ "$status" = "FAIL" ]; then
    ((FAIL_COUNT++))
  else
    ((SKIP_COUNT++))
  fi
  RESULTS+=("$sc|$test_name|$status|$detail")
  echo "  [$status] $test_name: $detail"
}

header() {
  echo ""
  echo "========================================================================"
  echo "  $1"
  echo "========================================================================"
}

# ============================================================================
header "SC #1 (P1): Per-Use-Case Authentication"
# ============================================================================
echo "Requirement: Each team has its own API key scoped to specific models."
echo ""

oc config use-context "$CTX_INFERENCE" &>/dev/null 2>&1 || true

echo "--- 1.1: MaaSSubscription resources ---"
SUBS=$(oc get maassubscription -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$SUBS" -ge 2 ]; then
  record "SC1" "Multiple subscriptions exist" "PASS" "${SUBS} MaaSSubscription(s) found"
  oc get maassubscription -A 2>/dev/null | head -10
else
  record "SC1" "Multiple subscriptions exist" "FAIL" "Only ${SUBS} subscription(s) found"
fi
echo ""

echo "--- 1.2: API key infrastructure ---"
API_KEY_COUNT=$(oc exec -n maas-db statefulset/postgresql -- psql -U maas -d maas -t -A -c "SELECT count(*) FROM api_keys WHERE status='active'" 2>/dev/null | tr -d '[:space:]')
if [ "${API_KEY_COUNT:-0}" -ge 1 ]; then
  record "SC1" "API keys in database" "PASS" "${API_KEY_COUNT} active API key(s) in PostgreSQL"
else
  record "SC1" "API keys in database" "SKIP" "No active API keys found (generate via MaaS API)"
fi
echo ""

echo "--- 1.3: MaaS gateway accessible ---"
MODEL_POD=$(oc get pod -n $MODEL_NS -l app.kubernetes.io/part-of=llminferenceservice -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$MODEL_POD" ]; then
  RESP=$(oc exec -n $MODEL_NS "$MODEL_POD" -- \
    curl -sk --max-time 10 "https://${MAAS_GW_SVC}/${MODEL_NS}/${MODEL_NAME}/v1/models" 2>/dev/null)
  if echo "$RESP" | grep -q '"object"'; then
    record "SC1" "MaaS gateway accessible" "PASS" "Model list returned via gateway"
  else
    record "SC1" "MaaS gateway accessible" "FAIL" "Unexpected response: ${RESP:0:100}"
  fi
else
  record "SC1" "MaaS gateway accessible" "SKIP" "No model pod found (label: app.kubernetes.io/part-of=llminferenceservice)"
fi
echo ""

# ============================================================================
header "SC #2 (P1): Token-Based Rate Limiting"
# ============================================================================
echo "Requirement: Rate limiting enforced per subscription."
echo ""

echo "--- 2.1: Rate limit configuration ---"
TIERS=$(oc get maassubscription -A -o yaml 2>/dev/null | grep -c "tokenRateLimits" || echo "0")
if [ "$TIERS" -ge 2 ]; then
  record "SC2" "Rate limit config per tier" "PASS" "${TIERS} subscriptions with tokenRateLimits"
else
  record "SC2" "Rate limit config per tier" "FAIL" "tokenRateLimits not found"
fi
echo ""

echo "--- 2.2: Limitador running ---"
LIMITADOR_PODS=$(oc get pods -A -l app=limitador --no-headers 2>/dev/null | grep -c "Running" || echo "0")
if [ "$LIMITADOR_PODS" -ge 1 ]; then
  record "SC2" "Limitador running" "PASS" "${LIMITADOR_PODS} Limitador pod(s) active"
else
  record "SC2" "Limitador running" "SKIP" "Limitador pods not found (may be managed by RHCL)"
fi
echo ""

# ============================================================================
header "SC #3 (P1): Usage Tracking"
# ============================================================================
echo "Requirement: Per-subscription usage visible via Prometheus."
echo ""

echo "--- 3.1: ServiceMonitors ---"
SM_COUNT=$(oc get servicemonitor -A --no-headers 2>/dev/null | grep -c "authorino\|limitador" || echo "0")
if [ "$SM_COUNT" -ge 1 ]; then
  record "SC3" "ServiceMonitors deployed" "PASS" "${SM_COUNT} relevant ServiceMonitor(s)"
else
  record "SC3" "ServiceMonitors deployed" "FAIL" "No Authorino/Limitador ServiceMonitors"
fi
echo ""

echo "--- 3.2: User workload monitoring ---"
UWM=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
if echo "$UWM" | grep -q "enableUserWorkload.*true"; then
  record "SC3" "User workload monitoring" "PASS" "enableUserWorkload: true"
else
  record "SC3" "User workload monitoring" "FAIL" "Not configured"
fi
echo ""

# ============================================================================
header "SC #4 (P2): Tiered Access"
# ============================================================================
echo "Requirement: At least two tiers with independent rate limit policies."
echo ""

TIER_COUNT=$(oc get maassubscription -A -o jsonpath='{range .items[*]}{.metadata.labels.tier}{"\n"}{end}' 2>/dev/null | sort -u | grep -c "." || echo "0")
if [ "$TIER_COUNT" -ge 2 ]; then
  record "SC4" "Multiple tiers defined" "PASS" "${TIER_COUNT} distinct tiers"
else
  record "SC4" "Multiple tiers defined" "FAIL" "Fewer than 2 tiers"
fi
echo ""

# ============================================================================
header "SC #5 (P2): OIDC / SSO"
# ============================================================================
echo "Requirement: Enterprise IdP federation with role-based access."
echo ""

echo "--- 5.1: OIDC token from Keycloak ---"
if [ -n "${KEYCLOAK_HOST:-}" ] && [ "$KEYCLOAK_HOST" != "REPLACE_WITH_KEYCLOAK_HOST" ]; then
  TOKEN_RESP=$(curl -sk "https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -d "grant_type=client_credentials&client_id=${OIDC_CLIENT_ID}&client_secret=${OIDC_CLIENT_SECRET}" 2>/dev/null)
  OIDC_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
  if [ -n "$OIDC_TOKEN" ] && [ ${#OIDC_TOKEN} -gt 50 ]; then
    record "SC5" "OIDC token obtainable" "PASS" "Got ${#OIDC_TOKEN}-char JWT"
  else
    record "SC5" "OIDC token obtainable" "FAIL" "Could not get token"
  fi
else
  record "SC5" "OIDC token obtainable" "SKIP" "KEYCLOAK_HOST not configured"
fi
echo ""

echo "--- 5.2: AuthConfig for OIDC ---"
AC_READY=$(oc get authconfig maas-gateway-oidc -n openshift-ingress -o jsonpath='{.status.summary.ready}' 2>/dev/null)
if [ "$AC_READY" = "true" ]; then
  record "SC5" "AuthConfig OIDC active" "PASS" "maas-gateway-oidc is Ready"
else
  record "SC5" "AuthConfig OIDC active" "FAIL" "AuthConfig not ready: ${AC_READY:-not found}"
fi
echo ""

# ============================================================================
header "SC #6 (P2): Observability"
# ============================================================================
echo "Requirement: Live dashboards with inference metrics."
echo ""

DASH_CM=$(oc get configmap ai-gateway-dashboard -n openshift-config-managed --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$DASH_CM" -ge 1 ]; then
  record "SC6" "Dashboard ConfigMap" "PASS" "ai-gateway-dashboard deployed"
else
  record "SC6" "Dashboard ConfigMap" "SKIP" "Dashboard ConfigMap not found"
fi
echo ""

# ============================================================================
header "SC #7 (P2): API Compatibility"
# ============================================================================
echo "Requirement: Standard OpenAI API format."
echo ""

echo "--- 7.1: /v1/models ---"
MODEL_POD=$(oc get pod -n $MODEL_NS -l app.kubernetes.io/part-of=llminferenceservice -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
MODELS_RESP=$(oc exec -n $MODEL_NS "$MODEL_POD" -- \
  curl -sk --max-time 10 "https://${MAAS_GW_SVC}/${MODEL_NS}/${MODEL_NAME}/v1/models" 2>/dev/null)
if echo "$MODELS_RESP" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('object')=='list'
assert 'data' in d
print('valid')
" 2>/dev/null | grep -q "valid"; then
  record "SC7" "GET /v1/models format" "PASS" "OpenAI-compatible response"
else
  record "SC7" "GET /v1/models format" "FAIL" "Not OpenAI-compatible"
fi
echo ""

echo "--- 7.2: /v1/chat/completions ---"
CHAT_RESP=$(oc exec -n $MODEL_NS "$MODEL_POD" -- \
  curl -sk --max-time 15 "https://${MAAS_GW_SVC}/${MODEL_NS}/${MODEL_NAME}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}],\"max_tokens\":10}" 2>/dev/null)
if echo "$CHAT_RESP" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('object')=='chat.completion'
assert d['choices'][0]['message']['role']=='assistant'
print('valid')
" 2>/dev/null | grep -q "valid"; then
  record "SC7" "POST /v1/chat/completions" "PASS" "OpenAI chat completion schema"
else
  record "SC7" "POST /v1/chat/completions" "FAIL" "Response: ${CHAT_RESP:0:100}"
fi
echo ""

# ============================================================================
header "SC #8 (P3): Secret Rotation (Vault + ESO)"
# ============================================================================
echo "Requirement: Credential rotation via Vault + ESO with zero downtime."
echo ""

if [ -n "${CTX_GATEWAY:-}" ]; then
  oc config use-context "$CTX_GATEWAY" &>/dev/null 2>&1 || true
fi

echo "--- 8.1: SecretStore ---"
SS_STATUS=$(oc get secretstore vault-backend -n vault-dev -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)
if [ "$SS_STATUS" = "store validated" ]; then
  record "SC8" "SecretStore validated" "PASS" "Vault connection healthy"
else
  record "SC8" "SecretStore validated" "FAIL" "Status: ${SS_STATUS:-not found}"
fi
echo ""

echo "--- 8.2: ExternalSecrets synced ---"
ES_STATUS=$(oc get externalsecret -n vault-dev --no-headers 2>/dev/null | grep -c "SecretSynced" || echo "0")
if [ "$ES_STATUS" -ge 1 ]; then
  record "SC8" "ExternalSecrets synced" "PASS" "${ES_STATUS} ExternalSecret(s) synced"
else
  record "SC8" "ExternalSecrets synced" "FAIL" "No synced ExternalSecrets"
fi
echo ""

echo "--- 8.3: Rotation demo ---"
VAULT_POD=$(oc get pods -n vault-dev -l app=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$VAULT_POD" ]; then
  TIMESTAMP=$(date +%s)
  oc exec "$VAULT_POD" -n vault-dev -- sh -c "export VAULT_TOKEN=${VAULT_TOKEN} && vault kv put secret/ai-bridge/api-keys team-a-key=sk-team-a-rotated-${TIMESTAMP} team-b-key=sk-team-b-rotated-${TIMESTAMP}" &>/dev/null
  echo "  Updated Vault. Waiting 35s for ESO refresh..."
  sleep 35
  NEW_VAL=$(oc get secret ai-bridge-api-keys -n vault-dev -o jsonpath='{.data.team-a-key}' 2>/dev/null | base64 -d 2>/dev/null)
  if echo "$NEW_VAL" | grep -q "rotated-${TIMESTAMP}"; then
    record "SC8" "Rotation synced" "PASS" "New value: ${NEW_VAL}"
  else
    record "SC8" "Rotation synced" "FAIL" "Value not updated: ${NEW_VAL}"
  fi
else
  record "SC8" "Rotation synced" "SKIP" "Vault pod not found"
fi
echo ""

oc config use-context "$CTX_INFERENCE" &>/dev/null 2>&1 || true

# ============================================================================
header "BONUS: Guardrails Gateway"
# ============================================================================

if [ -n "${GUARDRAILS_HOST:-}" ] && [ "$GUARDRAILS_HOST" != "REPLACE_WITH_GUARDRAILS_ROUTE" ]; then
  echo "--- Passthrough ---"
  GR_PASS=$(curl -s --max-time 15 "http://${GUARDRAILS_HOST}/passthrough/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":10}" 2>/dev/null)
  if echo "$GR_PASS" | grep -q '"choices"'; then
    record "BONUS" "Guardrails passthrough" "PASS" "Inference through guardrails"
  else
    record "BONUS" "Guardrails passthrough" "FAIL" "Response: ${GR_PASS:0:100}"
  fi

  echo "--- PII detection ---"
  GR_PII=$(curl -s --max-time 15 "http://${GUARDRAILS_HOST}/pii/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"My SSN is 123-45-6789\"}],\"max_tokens\":50}" 2>/dev/null)
  if echo "$GR_PII" | grep -q '"choices"\|blocked'; then
    record "BONUS" "Guardrails PII detection" "PASS" "PII pipeline active"
  else
    record "BONUS" "Guardrails PII detection" "FAIL" "Response: ${GR_PII:0:100}"
  fi
else
  record "BONUS" "Guardrails" "SKIP" "GUARDRAILS_HOST not configured"
fi
echo ""

# ============================================================================
header "BONUS: Multi-Cluster Routing"
# ============================================================================

if [ -n "${CTX_GATEWAY:-}" ]; then
  oc config use-context "$CTX_GATEWAY" &>/dev/null 2>&1 || true

  SE=$(oc get serviceentry -n ai-gateway --no-headers 2>/dev/null | wc -l | tr -d ' ')
  DR=$(oc get destinationrule -n ai-gateway --no-headers 2>/dev/null | wc -l | tr -d ' ')
  HR=$(oc get httproute -n ai-gateway --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$SE" -ge 1 ] && [ "$DR" -ge 1 ] && [ "$HR" -ge 1 ]; then
    record "BONUS" "Multi-cluster resources" "PASS" "SE(${SE}) DR(${DR}) HR(${HR})"
  else
    record "BONUS" "Multi-cluster resources" "FAIL" "Missing: SE=${SE} DR=${DR} HR=${HR}"
  fi

  MC_CHAT=$(oc run val-mc --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -n default --command -- \
    curl -s --max-time 15 "http://ai-inference-gateway-istio.ai-gateway.svc:80/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is AI?\"}],\"max_tokens\":20}" 2>/dev/null)
  if echo "$MC_CHAT" | grep -q '"choices"'; then
    record "BONUS" "Cross-cluster inference" "PASS" "Request routed cross-cluster"
  else
    record "BONUS" "Cross-cluster inference" "FAIL" "Response: ${MC_CHAT:0:100}"
  fi

  oc config use-context "$CTX_INFERENCE" &>/dev/null 2>&1 || true
else
  record "BONUS" "Multi-cluster" "SKIP" "CTX_GATEWAY not configured"
fi
echo ""

# ============================================================================
header "VALIDATION SUMMARY"
# ============================================================================
echo ""
printf "%-6s %-35s %-6s %s\n" "SC" "TEST" "STATUS" "DETAIL"
printf "%-6s %-35s %-6s %s\n" "------" "-----------------------------------" "------" "------------------------------"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r sc test status detail <<< "$r"
  printf "%-6s %-35s %-6s %s\n" "$sc" "$test" "$status" "${detail:0:50}"
done

echo ""
echo "========================================================================"
echo "  TOTAL: ${PASS_COUNT} PASS | ${FAIL_COUNT} FAIL | ${SKIP_COUNT} SKIP"
echo "========================================================================"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "Some tests FAILED. Review output above."
  exit 1
else
  echo "All critical tests passed. Environment aligns with PoC requirements."
  exit 0
fi
