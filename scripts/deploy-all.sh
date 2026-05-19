#!/bin/bash
# AI Bridge (MaaS) Demo — Deployment Script
# Deploys all components in the correct order.
#
# Usage:
#   ./scripts/deploy-all.sh [--profile single-cluster|multi-cluster]
#
# Prerequisites:
#   - oc CLI logged into the target cluster(s)
#   - scripts/config.env populated with your values
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="${1:-single-cluster}"

if [ ! -f "$SCRIPT_DIR/config.env" ]; then
  echo "ERROR: scripts/config.env not found."
  echo "  Copy scripts/config.env.example to scripts/config.env and fill in your values."
  exit 1
fi

source "$SCRIPT_DIR/config.env"

echo "=========================================="
echo "  AI Bridge (MaaS) Demo Deployment"
echo "  Profile: $PROFILE"
echo "=========================================="
echo ""

apply_manifests() {
  local dir="$1"
  local desc="$2"
  echo "--- Deploying: $desc ---"
  if [ -f "$dir/kustomization.yaml" ]; then
    oc apply -k "$dir"
  else
    oc apply -f "$dir/"
  fi
  echo ""
}

substitute_placeholders() {
  local file="$1"
  if [ -f "$file" ]; then
    sed -i.bak \
      -e "s|REPLACE_WITH_REMOTE_MODEL_HOSTNAME|${REMOTE_MODEL_HOSTNAME}|g" \
      -e "s|REPLACE_WITH_VLLM_SERVICE|${VLLM_SERVICE}|g" \
      -e "s|REPLACE_WITH_MAAS_GATEWAY_HOST|${MAAS_GW_HOST:-$MAAS_GW_SVC}|g" \
      -e "s|REPLACE_WITH_KEYCLOAK_ISSUER_URL|https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}|g" \
      -e "s|REPLACE_WITH_DB_PASSWORD|${DB_PASSWORD:-REPLACE_WITH_DB_PASSWORD}|g" \
      -e "s|REPLACE_WITH_GUARDRAILS_ROUTE|${GUARDRAILS_HOST}|g" \
      "$file"
    rm -f "${file}.bak"
  fi
}

# --- Phase 1: Platform Prerequisites (Inference Cluster) ---
echo "======== Phase 1: Platform Prerequisites ========"
oc config use-context "$CTX_INFERENCE" 2>/dev/null || true

apply_manifests "$REPO_ROOT/manifests/platform/monitoring-config" "User Workload Monitoring"
apply_manifests "$REPO_ROOT/manifests/platform/rhoai-instance" "RHOAI DataScienceCluster (MaaS)"
apply_manifests "$REPO_ROOT/manifests/platform/maas-postgres" "PostgreSQL (MaaS Backend)"
apply_manifests "$REPO_ROOT/manifests/platform/observability" "Observability (ServiceMonitors + Dashboard)"

echo "Waiting for MaaS gateway to be ready..."
oc wait --for=condition=Ready gateway/maas-default-gateway -n openshift-ingress --timeout=300s 2>/dev/null || echo "  (gateway may take a few minutes)"
echo ""

# --- Phase 2: Model Deployment ---
echo "======== Phase 2: Model Deployment ========"
apply_manifests "$REPO_ROOT/manifests/model" "Model (LLMInferenceService + Subscriptions)"

echo "Waiting for model download job..."
oc wait --for=condition=Complete job/download-qwen25-7b -n llm-inference --timeout=600s 2>/dev/null || echo "  (download may take several minutes)"
echo ""

# --- Phase 3: llm-d Endpoint Picker ---
echo "======== Phase 3: llm-d (Endpoint Picker) ========"
apply_manifests "$REPO_ROOT/manifests/llm-d" "llm-d EPP (InferencePool + InferenceModel)"
echo ""

# --- Phase 4: Guardrails Gateway ---
echo "======== Phase 4: Guardrails Gateway ========"
GUARD_DIR="$REPO_ROOT/manifests/guardrails"
substitute_placeholders "$GUARD_DIR/configmap.yaml"
substitute_placeholders "$GUARD_DIR/deployment.yaml"
apply_manifests "$GUARD_DIR" "Guardrails Gateway (PII Detection)"
echo ""

# --- Phase 5: OIDC Integration ---
echo "======== Phase 5: OIDC Integration ========"
OIDC_DIR="$REPO_ROOT/manifests/oidc"
substitute_placeholders "$OIDC_DIR/authconfig.yaml"
apply_manifests "$OIDC_DIR" "OIDC AuthConfig"
echo ""

# --- Phase 6: Vault + ESO ---
echo "======== Phase 6: Vault + External Secrets ========"
if [ "$PROFILE" = "multi-cluster" ]; then
  oc config use-context "$CTX_GATEWAY" 2>/dev/null || true
fi
apply_manifests "$REPO_ROOT/manifests/vault-eso" "Vault + External Secrets Operator"

echo "Waiting for Vault to be ready..."
oc wait --for=condition=Available deploy/vault -n vault-dev --timeout=120s 2>/dev/null || echo "  (Vault starting...)"

echo "Seeding Vault with demo secrets..."
VAULT_POD=$(oc get pods -n vault-dev -l app=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$VAULT_POD" ]; then
  oc exec "$VAULT_POD" -n vault-dev -- sh -c "
    export VAULT_TOKEN=${VAULT_TOKEN}
    vault kv put secret/ai-bridge/api-keys team-a-key=REPLACE_WITH_TEAM_A_KEY team-b-key=REPLACE_WITH_TEAM_B_KEY
    vault kv put secret/ai-bridge/db-credentials postgres-password=REPLACE_WITH_DB_PASSWORD postgres-url=postgresql://maas:REPLACE_WITH_DB_PASSWORD@postgresql.maas-db.svc:5432/maas
  "
  echo "  Vault seeded."
fi
echo ""

# --- Phase 7: Multi-Cluster Gateway (optional) ---
if [ "$PROFILE" = "multi-cluster" ]; then
  echo "======== Phase 7: Multi-Cluster AI Gateway ========"
  oc config use-context "$CTX_GATEWAY" 2>/dev/null || true
  GW_DIR="$REPO_ROOT/manifests/ai-gateway"
  substitute_placeholders "$GW_DIR/service-entry.yaml"
  substitute_placeholders "$GW_DIR/destination-rule.yaml"
  substitute_placeholders "$GW_DIR/httproute.yaml"
  apply_manifests "$GW_DIR" "AI Gateway (Multi-Cluster Routing)"
  echo ""
fi

# --- Done ---
echo "=========================================="
echo "  Deployment Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Wait for all pods to be Running: oc get pods -A | grep -E '(llm-inference|ai-guardrails|ai-gateway|vault-dev)'"
echo "  2. Run validation: ./scripts/validate-poc.sh"
echo ""
