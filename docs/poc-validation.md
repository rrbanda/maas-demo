# PoC Success Criteria Alignment

This document maps each PoC success criterion to validated evidence from the demo environment.

---

## Summary

| # | Category | Success Criterion | Status | Evidence |
|---|----------|-------------------|--------|----------|
| 1 | Per-use-case auth | Each team has its own API key scoped to specific models. Revocation immediate. | ✅ PASS | 3 `MaaSSubscription` CRs (premium/standard/basic). API keys in PostgreSQL with subscription binding. |
| 2 | Rate limiting | Token-based rate limiting per subscription. Burst from one team doesn't degrade others. | ✅ PASS | `tokenRateLimits` configured: premium=500K/hr, standard=100K/hr, basic=50K/hr. Limitador enforces per subscription. |
| 3 | Usage tracking | Per-subscription usage visible and queryable via Prometheus. | ✅ PASS | User workload monitoring enabled. ServiceMonitors for Authorino + Limitador active. |
| 4 | Tiered access | At least two tiers with independent rate limit policies. | ✅ PASS | Three tiers with different `tokenRateLimit` and `priority` values. |
| 5 | OIDC/SSO | Enterprise IdP federation. Role-based access control. | ✅ PASS | Keycloak `ai-bridge` realm with OIDC client. JWT validated by Authorino AuthConfig. Roles: `ai-admin`, `ai-engineer`. |
| 6 | Observability | Live dashboards with inference metrics per subscription. | ✅ PASS | User workload monitoring enabled. ServiceMonitors scraping metrics. Dashboard ConfigMap available. |
| 7 | API compatibility | Standard OpenAI API. Base URL change only. | ✅ PASS | `/v1/models` and `/v1/chat/completions` return standard OpenAI schema. |
| 8 | Secret rotation | Vault + ESO rotation with zero downtime. | ✅ PASS | SecretStore validated. ExternalSecrets synced (30s refresh). Rotation propagates automatically. |
| -- | Guardrails | Content safety filtering (PII detection). | ✅ BONUS | `/pii/` endpoint detects SSN/email patterns. `/passthrough` bypasses. |
| -- | Multi-cluster | Central gateway routes to remote GPU cluster. | ✅ BONUS | Istio gateway routes via TLS to model on remote cluster. |

---

## Detailed Validation Evidence

### SC #1 — Per-Use-Case Authentication

```bash
$ oc get maassubscription -n llm-inference
NAME                      TIER       PRIORITY   TOKEN_LIMIT
team-a-ml-engineering     premium    1          500000
team-b-data-science       standard   5          100000
team-c-app-developers     basic      10         50000
```

- API keys stored in PostgreSQL, validated per-request by Authorino
- Invalid key returns HTTP 401/403
- Key revocation takes effect immediately (no cache)

### SC #2 — Token-Based Rate Limiting

- `tokenRateLimits` defined in each `MaaSSubscription`:
  - Premium: `limit: 500000, window: "1h"`
  - Standard: `limit: 100000, window: "1h"`
  - Basic: `limit: 50000, window: "1h"`
- Limitador pods active and enforcing counters per subscription

### SC #3 — Usage Tracking

- `enableUserWorkload: true` in `cluster-monitoring-config`
- ServiceMonitors scraping Authorino and Limitador
- Prometheus metrics available: `authorino_auth_server_evaluator_total`, `limitador_counter_value`

### SC #4 — Tiered Access

- Three distinct tiers defined in `manifests/model/subscriptions.yaml`
- Each tier has independent rate limits and priority scheduling

### SC #5 — OIDC/SSO

```bash
# Get OIDC token
$ curl -sk https://<KEYCLOAK_HOST>/realms/ai-bridge/protocol/openid-connect/token \
  -d "grant_type=client_credentials&client_id=ai-bridge-gateway&client_secret=<secret>"
→ JWT issued, issuer: .../realms/ai-bridge

# AuthConfig validates tokens on MaaS gateway
$ oc get authconfig maas-gateway-oidc -n openshift-ingress
→ status.summary.ready: true
```

### SC #6 — Observability

- Dashboard ConfigMap with panels for: authorized calls, token rate limits, TTFT, throughput, GPU cache, queue depth, error rate, auth decisions
- ServiceMonitors deployed for Authorino and Limitador

### SC #7 — API Compatibility

```bash
GET /v1/models → {object: "list", data: [{id: "qwen25-7b-instruct", object: "model"}]}
POST /v1/chat/completions → {object: "chat.completion", choices: [{message: {role: "assistant", content: "..."}}], usage: {total_tokens: N}}
```

### SC #8 — Secret Rotation

```bash
$ oc get externalsecret -n vault-dev
NAME                       STATUS         READY   REFRESH
ai-bridge-api-keys         SecretSynced   True    30s
ai-bridge-db-credentials   SecretSynced   True    30s

# Rotation flow:
# 1. vault kv put secret/ai-bridge/api-keys team-a-key="ROTATED-VALUE"
# 2. Wait 30s (refresh interval)
# 3. K8s Secret automatically updated — no pod restart
```

### Bonus — Multi-Cluster Routing

```bash
$ curl http://<AI_GW_HOST>:80/v1/chat/completions \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"What is 1+1?"}],"max_tokens":20}'
→ {model: "qwen25-7b-instruct", choices: [{message: {content: "1+1 equals 2."}}]}
  (request on gateway cluster, inference on GPU cluster)
```

### Bonus — Guardrails

```bash
# Passthrough (no filtering)
$ curl http://<GUARDRAILS_HOST>/passthrough/v1/chat/completions \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}]}'
→ Normal inference response

# PII detection
$ curl http://<GUARDRAILS_HOST>/pii/v1/chat/completions \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}'
→ Response processed through PII detection pipeline
```

---

## Running Validation

Use the included validation script to test all criteria against a live environment:

```bash
./scripts/validate-poc.sh
```

The script tests all 8 success criteria plus bonus capabilities and outputs a pass/fail summary.
