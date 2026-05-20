# AI Bridge PoC — Tell-Show-Tell Demo Narrative

> **Terminology**: "AI Bridge" is the PoC project name. The official RHOAI 3.4 product feature is **Models-as-a-Service (MaaS)**. Where this document says "AI Bridge", the product equivalent is "MaaS" or "Models-as-a-Service governance gateway".

> **Format**: Each section follows TELL (why) → SHOW (how) → TELL (so what).
> **Target duration**: 45–60 minutes for full walkthrough.
> **Prerequisites**: Cluster deployed via `deploy-all.sh` or ArgoCD, `config.env` populated.

> **PoC Success Criteria Mapping** (from AI Bridge Scoping Document):
> | Demo Section | PoC Stage | Success Criteria |
> |---|---|---|
> | 1. GitOps Foundation | Stage A | SC-A1: Declarative multi-cluster deployment via ArgoCD |
> | 2. Model Registration | Stage A | SC-A2: Model available and serving inference |
> | 3.1 Multi-tenant Subscriptions | Stage B | SC-B1: Per-team subscription isolation |
> | 3.2 API Key Lifecycle | Stage B | SC-B2: Key generation, rotation, revocation |
> | 3.3 Token-based Rate Limiting | Stage B | SC-B3: Token-level enforcement, 429 on breach |
> | 3.4 Observability | Stage B | SC-B4: Usage visibility via built-in dashboard |
> | 3.5 Multi-cluster Gateway | Stage C | SC-C1: Cross-cluster routing with OIDC validation |
> | 4.1 Guardrails | Beyond Scope | Bonus demo — not required for PoC success |
>
> **Deployment Profile**: Multi-cluster (gateway cluster + inference cluster). This demonstrates cross-cluster routing and centralized governance — a key differentiator for enterprise deployments.

---

## Pre-Demo Setup Checklist

```bash
# Source environment config
source scripts/config.env

# Verify cluster access
oc whoami --show-server

# Verify all 5 MaaS CRDs are registered
oc api-resources | grep maas.opendatahub.io
# Expected: externalmodels, maasauthpolicies, maasmodelrefs, maassubscriptions, tenants

# Confirm Tenant is Active (controls gateway + key policies)
oc get tenant default-tenant -n models-as-a-service -o jsonpath='{.status.phase}'
# Expected: Active

# Confirm model is serving (takes ~5 min after deploy)
oc get pods -n llm-inference -l app.kubernetes.io/part-of=llminferenceservice
# Expected: 1/1 Running

# Confirm MaaS subscriptions are Active
oc get maassubscriptions -n models-as-a-service
# Expected: 3 subscriptions, all "Active"

# Confirm MaaSModelRef has governance attached
oc get maasmodelref qwen25-7b-instruct -n llm-inference -o jsonpath='{.status.phase}'
# Expected: Ready (means GovernanceAttached + RuntimeReady)
```

---

## 1. FOUNDATION (Stage A)

### 1.1 Platform Overview — RHOAI 3.4 with MaaS Enabled

**TELL**: RHOAI 3.4 introduces Models-as-a-Service as a GA capability. It adds a governance layer on top of model serving — turning raw GPU endpoints into managed API products with authentication, rate limiting, and usage tracking. This is enabled with a single configuration flag.

> **Technical Detail — MaaS CRD Model (all `maas.opendatahub.io/v1alpha1`)**:
>
> | CRD | Purpose |
> |-----|---------|
> | `Tenant` | Singleton (`default-tenant`) — configures gateway ref, key expiration, telemetry |
> | `MaaSModelRef` | Registers a model for governance; must pair with auth policy + subscription |
> | `MaaSAuthPolicy` | Defines which groups/users can access which models |
> | `MaaSSubscription` | Per-team quota with inline `tokenRateLimits` and priority |
> | `ExternalModel` | (Tech Preview) Routes to external providers like OpenAI, Anthropic |
>
> The `Tenant` CR **must exist** before any subscriptions can become Active. It defines the gateway reference (`maas-default-gateway` in `openshift-ingress`) and the maximum API key expiration policy.

**SHOW**:
```bash
# The DataScienceCluster CR enables MaaS
oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}'
# Expected: Managed

# Platform components are automatically provisioned
oc get pods -n redhat-ods-applications | grep maas
# Expected: maas-api, maas-controller pods Running

# Tenant CR — the MaaS control plane anchor
oc get tenant default-tenant -n models-as-a-service -o yaml
# Key fields:
#   spec.gatewayRef.name: maas-default-gateway
#   spec.gatewayRef.namespace: openshift-ingress
#   spec.apiKeys.maxExpirationDays: 90
#   status.phase: Active
```

**TELL**: With one configuration change, RHOAI 3.4 provisions the entire MaaS control plane — API server, controller, gateway infrastructure. The `Tenant` CR anchors the configuration: it binds MaaS to a specific gateway and sets organization-wide key policies. No manual assembly of components required.

**Estimated time**: 3 minutes

---

### 1.2 Model Deployed and Serving

**TELL**: A model is deployed using the standard RHOAI workflow. The `LLMInferenceService` CR (API: `serving.kserve.io/v1alpha2`) defines the model, resources, and GPU requirements. Once deployed, a `MaaSModelRef` registers it for governance. The model becomes "Ready" only when it has both governance attached (subscription + auth policy) AND the runtime is healthy.

> **Technical Detail — MaaSModelRef Status Phases**:
>
> | Phase | Meaning |
> |-------|---------|
> | Pending | Awaiting governance pairing or backend readiness |
> | Ready | Governed AND runtime-healthy (at least one active subscription + auth policy) |
> | Unhealthy | Governed but runtime-failed |
> | Failed | Non-recoverable reconciliation error |
> | Invalid | Bad spec (e.g., referencing non-existent model) |
>
> Status conditions: `GovernanceAttached`, `RuntimeReady`, `Ready`

**SHOW**:
```bash
# Model CR and its status (API: serving.kserve.io/v1alpha2)
oc get llminferenceservice -n llm-inference
# Expected: qwen25-7b-instruct with Ready status

# Model pod running with GPU
oc get pods -n llm-inference -l app.kubernetes.io/part-of=llminferenceservice
# Expected: 1/1 Running

# MaaSModelRef — governance registration status
oc get maasmodelref qwen25-7b-instruct -n llm-inference \
  -o jsonpath='{.status.phase}{"\n"}{.status.conditions[*].type}{"\n"}'
# Expected:
#   Ready
#   GovernanceAttached RuntimeReady Ready

# The MaaSModelRef discovers the endpoint automatically
oc get maasmodelref qwen25-7b-instruct -n llm-inference \
  -o jsonpath='{.status.endpoint}'
# Expected: the inference service's internal URL
```

**TELL**: The model is deployed with a declarative CR. RHOAI handles the vLLM runtime, GPU scheduling, and endpoint registration. The `MaaSModelRef` status proves governance is attached — the model won't serve traffic until subscriptions and auth policies are in place.

**Estimated time**: 3 minutes

---

### 1.3 OpenAI API Compatibility — Base URL Swap Only

**TELL**: One of the biggest adoption barriers is API compatibility. Existing applications using the OpenAI API format should work with the AI Bridge (MaaS gateway) endpoint by changing only the base URL. No SDK changes, no code modifications. The API key format is `sk-oai-*` — intentionally similar to OpenAI's format for developer familiarity.

**SHOW**:
```bash
# Standard OpenAI /v1/models endpoint (requires valid API key)
curl -sk "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/models" \
  -H "Authorization: Bearer ${API_KEY}" | python3 -m json.tool
# Expected: {"object": "list", "data": [{"id": "qwen25-7b-instruct", "object": "model", ...}]}

# Standard OpenAI /v1/chat/completions
curl -sk "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen25-7b-instruct",
    "messages": [{"role": "user", "content": "What is machine learning in one sentence?"}],
    "max_tokens": 50
  }' | python3 -m json.tool
# Expected: Standard chat completion response with choices[0].message.content
```

```python
# Python SDK example (identical to OpenAI usage)
from openai import OpenAI
client = OpenAI(
    base_url="https://<MAAS_GW_HOST>/llm-inference/qwen25-7b-instruct/v1",
    api_key="sk-oai-..."  # MaaS-generated key (same sk- prefix convention)
)
response = client.chat.completions.create(
    model="qwen25-7b-instruct",
    messages=[{"role": "user", "content": "Hello"}],
    max_tokens=20
)
print(response.choices[0].message.content)
```

**TELL**: The response format is identical to OpenAI's API. Any application using the OpenAI Python SDK, LangChain, or direct HTTP calls works with just a `base_url` change. The `sk-oai-` key prefix means existing credential management patterns carry over directly.

**Estimated time**: 5 minutes

---

### 1.4 Architecture Positioning — Where AI Bridge (MaaS) Sits

**TELL**: The AI Bridge (officially: Models-as-a-Service governance layer) is not replacing existing API management infrastructure. It complements it. An external API gateway continues to handle external consumer onboarding and organization-level policies. The MaaS gateway handles what generic gateways cannot: model-aware authentication, per-subscription token metering, and inference-specific rate limiting.

> **Technical Detail — What MaaS Controller Auto-Generates**:
>
> When you create a `MaaSSubscription` + `MaaSAuthPolicy` + `MaaSModelRef`, the MaaS controller automatically generates:
> 1. `HTTPRoute` (gateway.networking.k8s.io/v1) — routing to the model via the gateway
> 2. `AuthPolicy` (kuadrant.io/v1beta2) — API key validation via Authorino
> 3. `TokenRateLimitPolicy` (kuadrant.io/v1alpha1) — per-subscription token metering via Limitador
>
> You never create these manually. The MaaS controller reconciles them from your high-level CRDs.

**SHOW** (diagram on whiteboard or slide):
```
End Users → External API GW (org policies) → MaaS Gateway (model governance) → Model Endpoints (GPU)
                                                    │
                                            ┌───────┴────────┐
                                            │ Per-team keys  │
                                            │ Token metering │
                                            │ Rate limiting  │
                                            │ Usage tracking │
                                            └────────────────┘

Under the hood (auto-generated by MaaS controller):
  MaaSSubscription ──→ TokenRateLimitPolicy (kuadrant.io/v1alpha1)
  MaaSAuthPolicy   ──→ AuthPolicy (kuadrant.io/v1beta2)
  MaaSModelRef     ──→ HTTPRoute (gateway.networking.k8s.io/v1)
```

```bash
# The MaaS gateway endpoint is a single stable URL
echo "MaaS Gateway endpoint: https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1"

# Verify auto-generated Kuadrant policies (created by MaaS controller, not by us)
oc get tokenratelimitpolicies -A
# Expected: Auto-generated policies per subscription-model pair

oc get authpolicies -A -l opendatahub.io/managed=true
# Expected: Auto-generated auth policies for each model
```

**TELL**: The integration is a URL change in the external gateway's backend configuration. The MaaS gateway owns model-specific governance; the external gateway owns the external developer portal and organization-level policies. They are complementary layers.

**Estimated time**: 4 minutes

---

## 2. GOVERNANCE (Stage B)

### 2.1 Subscription Model — Three Teams, Three Tiers

**TELL**: Today, all use cases typically share a single API key per model. This creates a security blast radius — if one key leaks, all access is compromised. It also makes it impossible to track who is consuming what or enforce per-team limits. MaaS introduces subscriptions: each team gets its own isolated access with independent quotas.

> **Technical Detail — MaaSSubscription Spec (maas.opendatahub.io/v1alpha1)**:
>
> - `spec.priority`: Higher number = higher priority (premium=10, basic=1). Determines the default subscription when a user with multiple group memberships generates an API key without specifying one.
> - `spec.modelRefs[].tokenRateLimits`: REQUIRED (MinItems=1). Each entry has `limit` (1 to 1,000,000,000) and `window` (pattern: `^[1-9]\d{0,3}(s|m|h)$` — seconds, minutes, or hours only).
> - `spec.owner`: At least one group or user required. Maps to OpenShift/OIDC group memberships.
> - `status.phase`: Active | Failed. Only Active subscriptions can generate API keys.

**SHOW**:
```bash
# Three subscriptions with different tiers
oc get maassubscriptions -n models-as-a-service \
  -o custom-columns='NAME:.metadata.name,TIER:.metadata.labels.tier,PRIORITY:.spec.priority,PHASE:.status.phase'
# Expected:
# NAME                      TIER      PRIORITY   PHASE
# team-a-ml-engineering     premium   10         Active
# team-b-data-science       standard  5          Active
# team-c-app-developers     basic     1          Active

# Each subscription has independent token rate limits
oc get maassubscription team-a-ml-engineering -n models-as-a-service \
  -o jsonpath='{.spec.modelRefs[0].tokenRateLimits}' | python3 -m json.tool
# Expected: [{"limit": 500000, "window": "1h"}]

oc get maassubscription team-c-app-developers -n models-as-a-service \
  -o jsonpath='{.spec.modelRefs[0].tokenRateLimits}' | python3 -m json.tool
# Expected: [{"limit": 50000, "window": "1h"}]
```

**TELL**: Three teams, three tiers: premium (500K tokens/hr, priority 10), standard (100K tokens/hr, priority 5), basic (50K tokens/hr, priority 1). Each operates independently. A burst from the basic tier cannot impact the premium tier. Priority determines which subscription is selected as the default when a user belongs to multiple groups — it does not affect inference scheduling. This is all declarative — a YAML change, not an infrastructure project.

**Estimated time**: 4 minutes

---

### 2.2 API Key Creation and Scoped Access

**TELL**: Each subscription can generate its own API keys. Keys use the `sk-oai-` prefix, are scoped to the models that subscription is bound to, and expire based on the organization's policy (max 90 days, set in the Tenant CR). Keys are hashed in PostgreSQL and validated per-request by Authorino. No shared secrets between teams.

> **Technical Detail — API Key Properties**:
>
> | Property | Value |
> |----------|-------|
> | Prefix | `sk-oai-` |
> | Expiration | 1–365 days (admin-configurable max via `Tenant.spec.apiKeys.maxExpirationDays`, default 90) |
> | Storage | SHA-256 hash in PostgreSQL (`maas-db-config` secret in `redhat-ods-applications`) |
> | Group snapshot | Keys capture user's group memberships at creation time; later group changes don't affect existing keys |
> | Scope | Bound to subscription's `modelRefs` — only works for those models |
> | Validation | Per-request by Authorino (no caching — revocation is instant) |
> | Statuses | Active, Expired, Revoked |

**SHOW**:
```bash
# API keys are generated via the RHOAI dashboard or MaaS API
# Navigate to: RHOAI Dashboard → Models → qwen25-7b-instruct → Subscriptions
# Click on a subscription → Generate API Key
# Key will have format: sk-oai-<random-alphanumeric>

# Alternatively, temporary keys (1-hour TTL) from the Endpoints dialog:
# RHOAI Dashboard → Models → Endpoints → Generate Temporary Key

# The MaaS API endpoint for key management:
echo "MaaS API: https://$(oc get route maas-api -n redhat-ods-applications -o jsonpath='{.spec.host}')"

# Test with a valid API key (replace with generated key)
curl -sk "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-<YOUR_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
# Expected: 200 OK with model response

# Test with invalid key — should be rejected
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-invalid-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
# Expected: HTTP 401 or 403
```

**TELL**: Keys are per-team, scoped to specific models, hashed at rest, and validated on every request. The `sk-oai-` prefix makes them recognizable in logs and compatible with OpenAI SDK credential patterns. If a key leaks, only that team's access is compromised — and it can be revoked instantly without affecting others.

**Estimated time**: 5 minutes

---

### 2.3 Key Revocation — Immediate Effect

**TELL**: When a key needs to be revoked — whether due to a leak, personnel change, or rotation policy — it must take effect immediately. Not after a cache flush, not after a TTL expires. Immediately. The next request with that key must fail. Revocation is permanent and cannot be undone.

**SHOW**:
```bash
# Step 1: Confirm the key works
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-<TEAM_A_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Test"}],"max_tokens":5}'
# Expected: HTTP 200

# Step 2: Revoke the key (via RHOAI Dashboard → Subscription → Revoke Key)
# Note: Revocation is permanent — the key cannot be reactivated.
# Admins can also revoke ALL keys for a specific user.

# Step 3: Immediately retry the same key
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-<TEAM_A_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Test"}],"max_tokens":5}'
# Expected: HTTP 401 — key rejected on the very next request
```

**TELL**: Revocation is instantaneous. Authorino validates against the database on each request — there is no cache window where a revoked key could still be used. This meets the requirement for zero-downtime security response.

**Estimated time**: 3 minutes

---

### 2.4 Token-Based Rate Limiting — Burst Triggers 429

**TELL**: Request-based rate limiting is a blunt instrument — it treats a 10-token request the same as a 10,000-token request. Token-based rate limiting is model-aware: it meters actual consumption. A team that sends a few large prompts will hit their limit just as fairly as a team sending many small ones.

> **Technical Detail — How Token Metering Works**:
>
> 1. MaaS controller reads `tokenRateLimits` from `MaaSSubscription` and auto-generates a `TokenRateLimitPolicy` (kuadrant.io/v1alpha1)
> 2. Limitador intercepts inference responses and extracts `total_tokens` from the OpenAI-compatible `usage` field
> 3. Token count is accumulated per-user within the subscription (counter keyed by `auth.identity.userid`)
> 4. When the counter exceeds the limit within the window, Limitador returns HTTP 429
> 5. Counter resets automatically when the window expires
>
> Prometheus metrics emitted: `authorized_calls`, `limited_calls`, `limitador_counter_value`

**SHOW**:
```bash
# Current rate limits per tier
echo "Premium (team-a): 500,000 tokens/hour (priority 10)"
echo "Basic (team-c):    50,000 tokens/hour (priority 1)"

# Burst test: send rapid requests to consume the basic tier's quota
for i in $(seq 1 20); do
  RESP=$(curl -sk -w "%{http_code}" -o /tmp/resp.json \
    "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
    -H "Authorization: Bearer sk-oai-<TEAM_C_KEY>" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Write a detailed essay about the history of artificial intelligence from its origins to present day, covering all major milestones."}],"max_tokens":2000}')
  echo "Request $i: HTTP $RESP"
  [ "$RESP" = "429" ] && echo "  → Rate limit hit!" && break
done
# Expected: After consuming ~50K tokens, requests return HTTP 429

# Verify premium tier is unaffected during basic tier's rate limiting
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-<TEAM_A_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
# Expected: HTTP 200 — premium tier completely unaffected

# View the auto-generated TokenRateLimitPolicy
oc get tokenratelimitpolicies -n models-as-a-service -o wide
# Expected: One policy per subscription-model pair, each with the configured limits
```

**TELL**: The basic tier was rate-limited at its configured threshold. Meanwhile, the premium tier continued serving normally. Limitador counted actual tokens consumed (from the model's `usage.total_tokens` response field), not just request count. This is the core value: noisy-neighbor protection at the token level.

**Estimated time**: 5 minutes

---

### 2.5 Tiered Access — Independent Enforcement

**TELL**: Different teams have different needs. A production ML pipeline needs guaranteed high throughput. An internal dev team doing experiments needs access but shouldn't monopolize the GPU. Tiers formalize this with independent quotas and priorities.

**SHOW**:
```bash
# Show all three tiers side by side
oc get maassubscriptions -n models-as-a-service \
  -o custom-columns='TEAM:.metadata.name,TIER:.metadata.labels.tier,TOKENS_HR:.spec.modelRefs[0].tokenRateLimits[0].limit,PRIORITY:.spec.priority'
# Expected:
# TEAM                      TIER      TOKENS_HR   PRIORITY
# team-a-ml-engineering     premium   500000      10
# team-b-data-science       standard  100000      5
# team-c-app-developers     basic     50000       1

# Priority determines default subscription selection during API key creation
# Higher number = higher priority (used when a user belongs to multiple groups)
```

**TELL**: Three tiers, each with independent rate limits. Priority determines which subscription is selected as the default when a user belongs to multiple groups and generates an API key without specifying one. This is all configured declaratively — changing a tier is a YAML edit, not a re-architecture.

**Estimated time**: 2 minutes

---

### 2.6 Usage Tracking — Per-Subscription Metrics

**TELL**: Governance without visibility is blind. Teams need to know their usage, and admins need to see consumption across the organization. RHOAI 3.4 provides per-subscription usage tracking queryable through Prometheus and visible in the admin dashboard.

> **Technical Detail — Key Metrics**:
>
> | Metric | Source | Meaning |
> |--------|--------|---------|
> | `authorized_calls` | Limitador | Requests that passed rate limiting |
> | `limited_calls` | Limitador | Requests rejected with 429 |
> | `limitador_counter_value` | Limitador | Current token counter per subscription |
> | `limitador_counter_max_value` | Limitador | Configured limit value |
> | `auth_server_authconfig_total` | Authorino | Auth decisions (allow/deny) |
> | `vllm:generation_tokens_total` | vLLM | Tokens generated by the model |

**SHOW**:
```bash
# ServiceMonitors are scraping governance components
oc get servicemonitors -n kuadrant-system
# Expected: authorino-metrics, limitador-metrics

# Query Prometheus for rate limit counters per subscription
# (via OpenShift Console → Observe → Metrics)
echo "PromQL: authorized_calls{namespace='models-as-a-service'}"
echo "PromQL: limited_calls{namespace='models-as-a-service'}"
echo "PromQL: limitador_counter_value / limitador_counter_max_value"

# Query auth decisions
echo "PromQL: rate(auth_server_authconfig_total[5m])"

# View the dashboard
echo "OpenShift Console → Observe → Dashboards → AI Gateway - Multi-Tenant Inference"
```

Navigate to OpenShift Console → Observe → Dashboards and show:
- Authorized calls by subscription
- Token rate limit counters (current vs max)
- vLLM throughput and TTFT
- Auth allow/deny rates

**TELL**: Every request is metered. Admins see per-subscription token consumption in real time. This data feeds into chargeback models and capacity planning — no custom instrumentation required.

**Estimated time**: 4 minutes

---

## 3. ENTERPRISE INTEGRATION (Stage C)

### 3.1 OIDC/SSO Federation

**TELL**: API keys work for programmatic access. But human operators — admins managing subscriptions, engineers browsing the model catalog — should authenticate through the enterprise identity provider. The MaaS gateway federates with any OIDC-compliant IdP: the same SSO experience used for other internal tools.

> **Technical Detail — Dual Authentication Model**:
>
> MaaS supports two authentication methods simultaneously:
> 1. **API Keys** (`sk-oai-*`): Validated by Authorino against PostgreSQL. Used for programmatic/automated access.
> 2. **OIDC/JWT Tokens**: Validated against the configured IdP's JWKS endpoint. Used for interactive/human access.
>
> The `Tenant` CR has an optional `spec.externalOIDC` section (Tech Preview) that configures OIDC at the MaaS level:
> ```yaml
> spec:
>   externalOIDC:
>     issuerUrl: "https://keycloak.example.com/realms/ai-bridge"
>     clientId: "maas-client"
>     ttl: 300  # JWKS cache duration
> ```
>
> Separately, the multi-cluster gateway path uses a manually deployed `AuthConfig` (authorino.kuadrant.io/v1beta3) for OIDC enforcement.

**SHOW**:
```bash
# AuthConfig validates JWTs from the enterprise IdP (multi-cluster path)
oc get authconfig maas-gateway-oidc -n openshift-ingress \
  -o jsonpath='{.spec.authentication.oidc-jwt.jwt.issuerUrl}'
# Expected: https://<IDP_HOST>/realms/<realm>

# Get a token from the IdP (client credentials flow)
TOKEN=$(curl -sk "https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=${OIDC_CLIENT_ID}&client_secret=${OIDC_CLIENT_SECRET}" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
echo "Token obtained (${#TOKEN} chars)"

# Access the gateway with OIDC token
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/models" \
  -H "Authorization: Bearer $TOKEN"
# Expected: HTTP 200 — OIDC auth accepted
```

**TELL**: The MaaS gateway validates tokens from the enterprise IdP on every request. This means the same identity that logs into internal tools is the identity that accesses models — unified audit trail, unified access policies.

**Estimated time**: 4 minutes

---

### 3.2 Role-Based Access Control

**TELL**: Not everyone should have the same permissions. An AI Engineer should be able to use models and view their own usage. An AI Admin should be able to create subscriptions, manage keys, and see all usage. RBAC is enforced at the gateway level based on JWT roles.

> **Technical Detail — RHOAI Dashboard Feature Flags**:
>
> Admin vs user capabilities are controlled in `OdhDashboardConfig`:
> ```yaml
> spec:
>   dashboardConfig:
>     modelAsService: true       # Admin: manage subscriptions, auth policies
>     genAiStudio: true          # User: models tab, API key generation
>     maasAuthPolicies: true     # Admin: auth policy management UI
>     observabilityDashboard: true  # Usage monitoring (Tech Preview)
> ```

**SHOW**:
```bash
# The AuthConfig enforces role-based access
oc get authconfig maas-gateway-oidc -n openshift-ingress \
  -o jsonpath='{.spec.authorization.role-check.patternMatching.patterns[0].predicate}'
# Expected: auth.identity.realm_access.roles.exists(r, r == "ai-admin" || r == "ai-engineer")

# Decode the JWT to show roles
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool | grep -A5 "realm_access"
# Expected: "roles": ["ai-admin"] or ["ai-engineer"]

# A token WITHOUT the required role would be rejected:
# HTTP 403 — authenticated but not authorized
```

**TELL**: Authentication answers "who are you?" Authorization answers "what can you do?" The MaaS gateway enforces both. Role assignments are managed in the IdP, not duplicated in the AI platform.

**Estimated time**: 3 minutes

---

### 3.3 Secret Rotation — Vault + ESO, Zero Downtime

**TELL**: Credentials need to rotate. Database passwords expire, API keys get compromised, compliance requires periodic rotation. The platform integrates with HashiCorp Vault via the External Secrets Operator. Secrets rotate in Vault, and within 30 seconds, all consuming workloads have the new value — no pod restarts, no manual intervention.

**SHOW**:
```bash
# SecretStore is validated (Vault connection healthy)
oc get secretstore vault-backend -n vault-dev -o jsonpath='{.status.conditions[0].message}'
# Expected: store validated

# ExternalSecrets are synced
oc get externalsecrets -n vault-dev
# Expected: ai-bridge-api-keys (SecretSynced), ai-bridge-db-credentials (SecretSynced)

# Demonstrate rotation: update a secret in Vault
VAULT_POD=$(oc get pods -n vault-dev -l app=vault -o jsonpath='{.items[0].metadata.name}')
TIMESTAMP=$(date +%s)
oc exec "$VAULT_POD" -n vault-dev -- sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=\$VAULT_DEV_ROOT_TOKEN_ID \
   vault kv put secret/ai-bridge/api-keys team-a-key=rotated-${TIMESTAMP} team-b-key=rotated-${TIMESTAMP}"
echo "Secret updated in Vault at $(date)"

# Wait for ESO refresh (30s interval)
echo "Waiting 35 seconds for ESO to sync..."
sleep 35

# Verify the K8s Secret was updated automatically
oc get secret ai-bridge-api-keys -n vault-dev -o jsonpath='{.data.team-a-key}' | base64 -d
# Expected: rotated-<timestamp> — matches what we put in Vault
echo ""
echo "Secret rotation completed with zero downtime."
```

**TELL**: The secret was updated in Vault and within 30 seconds, the Kubernetes Secret was updated automatically. No pod restarts, no manual intervention, no outage window. This is the pattern for credential rotation at scale.

**Estimated time**: 5 minutes (includes 35s wait)

---

### 3.4 Observability — Dashboards and Metrics

**TELL**: Governance without observability is incomplete. Operators need to see: Who is using what? Are rate limits being hit? What is the inference latency? RHOAI 3.4 MaaS includes a built-in **Perses dashboard** embedded in the OpenShift AI console (Technology Preview). It visualizes token usage, rate limit status, and subscription activity out of the box. Additionally, standard Prometheus metrics are exposed for custom alerting.

> **Note**: The MaaS observability dashboard is Perses-based and embedded in the OpenShift AI console. It is a **Technology Preview** feature in RHOAI 3.4 — not a separate Grafana deployment.

**SHOW**:
```bash
# User workload monitoring is enabled (prerequisite)
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}'
# Expected: enableUserWorkload: true

# Verify Limitador metrics are being scraped
oc get servicemonitor -n redhat-ods-applications | grep -i limitador

# Key Limitador metrics (source of truth for rate limiting):
echo "=== Key PromQL Queries (Limitador) ==="
echo "1. Authorized tokens:    sum(authorized_hits{namespace='models-as-a-service'})"
echo "2. Authorized calls:     sum(authorized_calls{namespace='models-as-a-service'})"
echo "3. Rate-limited calls:   sum(limited_calls{namespace='models-as-a-service'})"
echo ""
echo "=== Inference Metrics (vLLM) ==="
echo "4. Token throughput:     rate(vllm:generation_tokens_total[5m])"
echo "5. Time to First Token:  histogram_quantile(0.95, rate(vllm:time_to_first_token_seconds_bucket[5m]))"
echo "6. Error rate:           rate(envoy_cluster_upstream_rq_xx{envoy_response_code_class=~'4|5'}[5m])"
```

Navigate to OpenShift AI Console → Models-as-a-Service → Usage Dashboard (Perses-based, Tech Preview).

**TELL**: The built-in Perses dashboard shows token consumption per subscription, rate limit utilization, and 429 rejection rates. For custom alerting, the same Limitador metrics (`authorized_hits`, `authorized_calls`, `limited_calls`) are available via the Prometheus stack already deployed — no additional infrastructure needed.

**Estimated time**: 4 minutes

---

## 4. BONUS CAPABILITIES (Beyond PoC Scope)

> **Note**: The following sections demonstrate additional capabilities that are NOT required for PoC success criteria validation. They are included as forward-looking differentiators.

### 4.1 Guardrails — PII Regex Detection

**TELL**: Content safety is a growing concern for model deployment. While full LLM-based content analysis is on the roadmap, the architecture for inline guardrails is available today. This demo shows a regex-based PII detector that inspects requests before they reach the model.

**SHOW**:
```bash
# Guardrails pod is running with two containers: gateway + orchestrator
oc get pods -n ai-guardrails
# Expected: guardrails-gateway 2/2 Running

# Passthrough route (no filtering)
curl -sk "http://${GUARDRAILS_HOST}/passthrough/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":20}' \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['choices'][0]['message']['content'])"
# Expected: Normal model response

# PII detection route (scans for email, SSN, credit card patterns)
curl -sk "http://${GUARDRAILS_HOST}/pii/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"My SSN is 123-45-6789 and email is test@example.com"}],"max_tokens":50}' \
  | python3 -m json.tool
# Expected: Response with detections field populated (PII patterns found)
```

**TELL**: The guardrails gateway inspects traffic inline without changing the model. Today it uses regex patterns; the same architecture supports LLM-based detectors (TrustyAI) as they mature. The pattern is proven — only the detector sophistication changes.

**Estimated time**: 4 minutes

---

### 4.2 Multi-Cluster Routing with OIDC Auth

**TELL**: In production, the MaaS gateway may run on a separate CPU cluster while models run on GPU clusters across sites. This demo shows multi-cluster routing where the gateway validates OIDC tokens locally, then forwards authenticated requests to a remote model endpoint via TLS.

**SHOW**:
```bash
# Gateway on the CPU cluster routes to model on GPU cluster
# Unauthenticated request → rejected at gateway
curl -s -w "HTTP %{http_code}\n" -o /dev/null \
  "http://${AI_GW_HOST}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hi"}],"max_tokens":5}'
# Expected: HTTP 401

# Authenticated request → routed cross-cluster to model
curl -s "http://${AI_GW_HOST}/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hi"}],"max_tokens":10}' \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['choices'][0]['message']['content'])"
# Expected: Model response (request traversed from gateway cluster to inference cluster)
```

**TELL**: The gateway cluster has no GPUs — it only handles auth and routing. The inference cluster has GPUs but no external exposure. Together they demonstrate the production pattern where governance and compute are decoupled.

**Estimated time**: 3 minutes

---

### 4.3 GitOps Deployment Model

**TELL**: Everything demonstrated today is declarative and stored in Git. ArgoCD manages the deployment, Kustomize handles environment-specific values, and secrets are managed through Vault — never stored in the repository. This is the production-grade deployment pattern.

**SHOW**:
```bash
# ArgoCD applications managing the stack
oc get applications.argoproj.io -A | grep maas-demo
# Expected: maas-demo-gateway (Synced/Healthy), maas-demo-inference (Synced/Healthy)

# Repository structure
echo "github.com/rrbanda/maas-demo"
echo "├── manifests/          ← base resources (no secrets, no env-specific values)"
echo "│   └── model/          ← Tenant, MaaSModelRef, MaaSSubscriptions, MaaSAuthPolicy"
echo "├── profiles/           ← composition (single-cluster or multi-cluster)"
echo "├── clusters/live/      ← environment overlays (Kustomize patches)"
echo "└── scripts/            ← deploy, teardown, validate"
```

**TELL**: Infrastructure as code, secrets in Vault, deployment via ArgoCD. A new environment is a new overlay directory — no manual steps, fully auditable, reproducible.

**Estimated time**: 2 minutes

---

## Demo Closing

**TELL**: What we demonstrated today:

1. **Foundation**: RHOAI 3.4 with MaaS enabled (5 CRDs, Tenant anchor, auto-generated gateway policies), model serving with OpenAI-compatible API (`sk-oai-` keys), seamless integration point for existing API management
2. **Governance**: Per-team subscriptions with independent API keys, token-based rate limiting (Limitador counting `total_tokens` from response), three-tier priority model, real-time usage tracking
3. **Enterprise Integration**: OIDC/SSO federation with role-based access, zero-downtime secret rotation via Vault, full observability through Prometheus and dashboards

All of this is:
- **Declarative** — YAML CRDs, controller-reconciled (MaaS controller auto-generates Kuadrant policies)
- **GitOps-managed** — auditable, reproducible, rollback-capable
- **API-compatible** — existing applications need only a base URL change
- **Complementary** — works alongside existing API management infrastructure

---

## Fallback Commands

If something fails during the live demo, use these to show pre-captured evidence:

```bash
# If model isn't responding, show it from inside the cluster
oc exec -n llm-inference deployment/llm-d-epp -- \
  curl -sk --max-time 10 "https://qwen25-7b-instruct-kserve-workload-svc.llm-inference.svc:8000/v1/models"

# If MaaS gateway isn't accessible externally, test internally
oc run test-gw --rm -i --restart=Never --image=curlimages/curl -n default -- \
  curl -sk "https://maas-default-gateway-data-science-gateway-class.openshift-ingress.svc:443/llm-inference/qwen25-7b-instruct/v1/models"

# If rate limiting hasn't triggered, show the auto-generated policy
oc get tokenratelimitpolicies -n models-as-a-service -o yaml

# If subscriptions aren't Active, check Tenant status first
oc get tenant default-tenant -n models-as-a-service -o yaml

# If MaaSModelRef isn't Ready, check conditions
oc get maasmodelref qwen25-7b-instruct -n llm-inference -o jsonpath='{.status.conditions}' | python3 -m json.tool

# If Vault rotation is slow, show current ExternalSecret status
oc get externalsecrets -n vault-dev -o wide
```

---

## Timing Summary

| Section | Topic | Time |
|---------|-------|------|
| 1.1 | Platform Overview + Tenant | 3 min |
| 1.2 | Model Serving + MaaSModelRef Status | 3 min |
| 1.3 | API Compatibility | 5 min |
| 1.4 | Architecture + Auto-Generated Policies | 4 min |
| 2.1 | Subscription Model | 4 min |
| 2.2 | API Key Creation (`sk-oai-`) | 5 min |
| 2.3 | Key Revocation | 3 min |
| 2.4 | Rate Limiting (TokenRateLimitPolicy) | 5 min |
| 2.5 | Tiered Access | 2 min |
| 2.6 | Usage Tracking | 4 min |
| 3.1 | OIDC/SSO + Dual Auth | 4 min |
| 3.2 | Role-Based Access | 3 min |
| 3.3 | Secret Rotation | 5 min |
| 3.4 | Observability | 4 min |
| 4.1 | Guardrails (bonus) | 4 min |
| 4.2 | Multi-cluster (bonus) | 3 min |
| 4.3 | GitOps (bonus) | 2 min |
| **Total** | | **~63 min** |

**For a 45-minute slot**: Skip sections 4.1–4.3 (bonus) and condense 2.5 into 2.1.
**For a 30-minute slot**: Cover 1.1, 1.3, 2.1, 2.2, 2.4, 3.1, 3.3 only (core value props).

---

## Appendix: Prerequisites (from RHOAI 3.4 docs)

| Requirement | Detail |
|-------------|--------|
| OpenShift | 4.19.9+ |
| RHOAI Operator | 3.4+ |
| Red Hat Connectivity Link (RHCL) | 1.2+ (provides Kuadrant/Authorino/Limitador) |
| `Kuadrant` CR | In `kuadrant-system` with Ready status |
| `GatewayClass` | `openshift.io/gateway-controller` |
| User Workload Monitoring | Enabled in `cluster-monitoring-config` |
| PostgreSQL | For API key hash storage |
| NVIDIA GPU Operator | 25.x (for GPU nodes) |
