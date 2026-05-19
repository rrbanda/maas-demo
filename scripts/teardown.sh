#!/bin/bash
# AI Bridge (MaaS) Demo — Teardown Script
# Removes all demo components in reverse order.
#
# Usage: ./scripts/teardown.sh [--profile single-cluster|multi-cluster]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="${1:-single-cluster}"

if [ -f "$SCRIPT_DIR/config.env" ]; then
  source "$SCRIPT_DIR/config.env"
fi

echo "=========================================="
echo "  AI Bridge (MaaS) Demo Teardown"
echo "  Profile: $PROFILE"
echo "=========================================="
echo ""
echo "WARNING: This will delete all demo resources."
read -p "Continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

delete_manifests() {
  local dir="$1"
  local desc="$2"
  echo "--- Removing: $desc ---"
  if [ -f "$dir/kustomization.yaml" ]; then
    oc delete -k "$dir" --ignore-not-found 2>/dev/null || true
  else
    oc delete -f "$dir/" --ignore-not-found 2>/dev/null || true
  fi
}

# Multi-cluster gateway
if [ "$PROFILE" = "multi-cluster" ] && [ -n "${CTX_GATEWAY:-}" ]; then
  oc config use-context "$CTX_GATEWAY" &>/dev/null 2>&1 || true
  delete_manifests "$REPO_ROOT/manifests/ai-gateway" "AI Gateway"
fi

# Vault + ESO
delete_manifests "$REPO_ROOT/manifests/vault-eso" "Vault + ESO"

# Switch to inference cluster
if [ -n "${CTX_INFERENCE:-}" ]; then
  oc config use-context "$CTX_INFERENCE" &>/dev/null 2>&1 || true
fi

# OIDC
delete_manifests "$REPO_ROOT/manifests/oidc" "OIDC AuthConfig"

# Guardrails
delete_manifests "$REPO_ROOT/manifests/guardrails" "Guardrails Gateway"

# llm-d
delete_manifests "$REPO_ROOT/manifests/llm-d" "llm-d EPP"

# Model
delete_manifests "$REPO_ROOT/manifests/model" "Model"

# Platform
delete_manifests "$REPO_ROOT/manifests/platform/observability" "Observability"
delete_manifests "$REPO_ROOT/manifests/platform/maas-postgres" "PostgreSQL"

# Delete namespaces
echo ""
echo "--- Removing namespaces ---"
oc delete ns llm-inference ai-guardrails ai-gateway maas-db vault-dev --ignore-not-found 2>/dev/null || true

echo ""
echo "=========================================="
echo "  Teardown Complete"
echo "=========================================="
