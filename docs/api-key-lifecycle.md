# API Key Lifecycle — Create, Rotate, Revoke

This document describes the API key lifecycle operations for MaaS subscriptions in RHOAI 3.4.

## Overview

Each `MaaSSubscription` can have multiple API keys. Keys are:
- **Scoped** to the models bound to that subscription
- **Hashed** at rest in PostgreSQL (not retrievable after creation)
- **Validated per-request** by the MaaS gateway (Authorino)
- **Immediately effective** on creation or revocation (no cache delay)

## Key Operations

### 1. Create an API Key

**Via RHOAI Dashboard (recommended for demo):**

1. Navigate to RHOAI Dashboard
2. Go to **Models** → select the model (e.g., `qwen25-7b-instruct`)
3. Click **Subscriptions** tab
4. Select a subscription (e.g., `team-a-ml-engineering`)
5. Click **Generate API Key**
6. Copy the key immediately (it will not be shown again)

**Via MaaS API (programmatic):**

```bash
# Get the MaaS API endpoint
MAAS_API="https://$(oc get route maas-api -n redhat-ods-applications -o jsonpath='{.spec.host}')"

# Create a key for a subscription (requires admin session)
# Note: The exact API may vary by RHOAI version. Check dashboard network tab for current endpoints.
curl -sk -X POST "${MAAS_API}/api/v1/subscriptions/team-a-ml-engineering/keys" \
  -H "Authorization: Bearer <ADMIN_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"name": "team-a-primary-key"}'
# Response: {"key": "sk-...", "name": "team-a-primary-key", "created_at": "..."}
```

### 2. Verify Key Works

```bash
# Test the newly created key
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer <NEW_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
# Expected: HTTP 200
```

### 3. Rotate a Key

Key rotation = create new key, update consumers, revoke old key.

```bash
# Step 1: Create a new key (see above)
# Step 2: Update consuming applications with the new key
# Step 3: Revoke the old key (see below)
# Zero downtime: both keys work simultaneously during the transition
```

### 4. Revoke a Key

**Via RHOAI Dashboard:**

1. Navigate to the subscription's key list
2. Click **Revoke** on the target key
3. Confirm the revocation

**Via MaaS API:**

```bash
curl -sk -X DELETE "${MAAS_API}/api/v1/subscriptions/team-a-ml-engineering/keys/<KEY_ID>" \
  -H "Authorization: Bearer <ADMIN_TOKEN>"
# Response: 204 No Content
```

**Verify immediate revocation:**

```bash
# This request should now fail immediately
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer <REVOKED_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
# Expected: HTTP 401 — immediate rejection, no cache delay
```

## Verify Key Storage (Hashed)

```bash
# Keys are stored as hashes in PostgreSQL — not reversible
oc exec -n maas-db statefulset/postgresql -- \
  psql -U maas -d maas -c "SELECT subscription_name, LEFT(key_hash, 20) || '...' as hash, status, created_at FROM api_keys;"
# Expected: Hashed values, status='active' or 'revoked'
```

## Key Properties

| Property | Value |
|----------|-------|
| Format | `sk-` prefix + random alphanumeric |
| Storage | SHA-256 hash in PostgreSQL |
| Scope | Bound to subscription's modelRefs |
| Validation | Per-request (no caching) |
| Revocation latency | Immediate (next request) |
| Max keys per subscription | Configurable (default: unlimited) |

## Demo Script (Quick Lifecycle Demo)

```bash
#!/bin/bash
# Quick API key lifecycle demonstration
echo "=== Step 1: Generate key via RHOAI Dashboard ==="
echo "  → Navigate to Dashboard → Models → Subscriptions → Generate Key"
read -p "  Paste the generated key: " API_KEY

echo ""
echo "=== Step 2: Verify key works ==="
curl -sk -w "\n  HTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":5}'

echo ""
echo "=== Step 3: Revoke key via RHOAI Dashboard ==="
echo "  → Navigate to Dashboard → Subscription → Revoke Key"
read -p "  Press Enter after revoking..."

echo ""
echo "=== Step 4: Verify immediate revocation ==="
curl -sk -w "\n  HTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":5}'
echo "  Expected: HTTP 401 (key revoked)"
```
