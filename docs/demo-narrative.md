# AI Bridge PoC — Tell-Show-Tell Demo Narrative

> **Format**: Each section follows TELL (why) → SHOW (how) → TELL (so what).
> **Target duration**: 45–60 minutes for full walkthrough.
> **Prerequisites**: Cluster deployed via `deploy-all.sh` or ArgoCD, `config.env` populated.

---

## Pre-Demo Setup Checklist

```bash
# Source environment config
source scripts/config.env

# Verify cluster access
oc whoami --show-server

# Confirm model is serving (takes ~5 min after deploy)
oc get pods -n llm-inference -l app.kubernetes.io/part-of=llminferenceservice
# Expected: 1/1 Running

# Confirm MaaS subscriptions are Active
oc get maassubscriptions -A
# Expected: 3 subscriptions, all "Active"
```

---

## 1. FOUNDATION (Stage A)

### 1.1 Platform Overview — RHOAI 3.4 with MaaS Enabled

**TELL**: RHOAI 3.4 introduces Models-as-a-Service as a GA capability. It adds a governance layer on top of model serving — turning raw GPU endpoints into managed API products with authentication, rate limiting, and usage tracking. This is enabled with a single configuration flag.

**SHOW**:
```bash
# The DataScienceCluster CR enables MaaS
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}'
# Expected: Managed

# Platform components are automatically provisioned
oc get pods -n redhat-ods-applications | grep maas
# Expected: maas-api, maas-controller pods Running
```

**TELL**: With one configuration change, RHOAI 3.4 provisions the entire MaaS control plane — API server, controller, gateway infrastructure. No manual assembly of components required.

**Estimated time**: 2 minutes

---

### 1.2 Model Deployed and Serving

**TELL**: A model is deployed using the standard RHOAI workflow. The `LLMInferenceService` CR defines the model, resources, and GPU requirements. Once deployed, it automatically registers with the MaaS gateway and becomes available through a governed endpoint.

**SHOW**:
```bash
# Model CR and its status
oc get llminferenceservice -n llm-inference
# Expected: qwen25-7b-instruct with Ready status

# Model pod running with GPU
oc get pods -n llm-inference -l app.kubernetes.io/part-of=llminferenceservice
# Expected: 1/1 Running

# MaaS model reference (registers model for governance)
oc get maasmodelref -n llm-inference
# Expected: qwen25-7b-instruct, Ready
```

**TELL**: The model is deployed with a declarative CR. RHOAI handles the vLLM runtime, GPU scheduling, and endpoint registration. No manual service creation or routing configuration needed.

**Estimated time**: 3 minutes

---

### 1.3 OpenAI API Compatibility — Base URL Swap Only

**TELL**: One of the biggest adoption barriers is API compatibility. Existing applications using the OpenAI API format should work with the AI Bridge endpoint by changing only the base URL. No SDK changes, no code modifications.

**SHOW**:
```bash
# Standard OpenAI /v1/models endpoint
curl -sk "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/models" | python3 -m json.tool
# Expected: {"object": "list", "data": [{"id": "qwen25-7b-instruct", "object": "model", ...}]}

# Standard OpenAI /v1/chat/completions
curl -sk "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
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
    api_key="<subscription-api-key>"
)
response = client.chat.completions.create(
    model="qwen25-7b-instruct",
    messages=[{"role": "user", "content": "Hello"}],
    max_tokens=20
)
print(response.choices[0].message.content)
```

**TELL**: The response format is identical to OpenAI's API. Any application using the OpenAI Python SDK, LangChain, or direct HTTP calls works with just a `base_url` change. This means zero code changes for consuming teams.

**Estimated time**: 5 minutes

---

### 1.4 Architecture Positioning — Where AI Bridge Sits

**TELL**: The AI Bridge is not replacing existing API management infrastructure. It complements it. An external API gateway continues to handle external consumer onboarding and organization-level policies. The AI Bridge handles what generic gateways cannot: model-aware authentication, per-subscription token metering, and inference-specific rate limiting.

**SHOW** (diagram on whiteboard or slide):
```
End Users → External API GW (org policies) → AI Bridge (model governance) → Model Endpoints (GPU)
                                                    │
                                            ┌───────┴────────┐
                                            │ Per-team keys  │
                                            │ Token metering │
                                            │ Rate limiting  │
                                            │ Usage tracking │
                                            └────────────────┘
```

```bash
# The MaaS gateway endpoint is a single stable URL
echo "AI Bridge endpoint: https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1"
# An external API gateway would point to this URL as its backend
```

**TELL**: The integration is a URL change in the external gateway's backend configuration. The AI Bridge owns model-specific governance; the external gateway owns the external developer portal and organization-level policies. They are complementary layers.

**Estimated time**: 3 minutes

---

## 2. GOVERNANCE (Stage B)

### 2.1 Subscription Model — Three Teams, Three Tiers

**TELL**: Today, all use cases typically share a single API key per model. This creates a security blast radius — if one key leaks, all access is compromised. It also makes it impossible to track who is consuming what or enforce per-team limits. The AI Bridge introduces subscriptions: each team gets its own isolated access with independent quotas.

**SHOW**:
```bash
# Three subscriptions with different tiers
oc get maassubscriptions -n models-as-a-service \
  -o custom-columns='NAME:.metadata.name,TIER:.metadata.labels.tier,PRIORITY:.spec.priority,PHASE:.status.phase'
# Expected:
# NAME                      TIER      PRIORITY   PHASE
# team-a-ml-engineering     premium   1          Active
# team-b-data-science       standard  5          Active
# team-c-app-developers     basic     10         Active

# Each subscription has independent token rate limits
oc get maassubscription team-a-ml-engineering -n models-as-a-service \
  -o jsonpath='{.spec.modelRefs[0].tokenRateLimits}' | python3 -m json.tool
# Expected: [{"limit": 500000, "window": "1h"}]

oc get maassubscription team-c-app-developers -n models-as-a-service \
  -o jsonpath='{.spec.modelRefs[0].tokenRateLimits}' | python3 -m json.tool
# Expected: [{"limit": 50000, "window": "1h"}]
```

**TELL**: Three teams, three tiers: premium (500K tokens/hr), standard (100K tokens/hr), basic (50K tokens/hr). Each operates independently. A burst from the basic tier cannot impact the premium tier. This is all declarative — a YAML change, not an infrastructure project.

**Estimated time**: 4 minutes

---

### 2.2 API Key Creation and Scoped Access

**TELL**: Each subscription can generate its own API keys. Keys are scoped — they only work for the models that subscription is bound to. The keys are hashed in PostgreSQL and validated per-request by the gateway. No shared secrets between teams.

**SHOW**:
```bash
# API keys are generated via the RHOAI dashboard or MaaS API
# Navigate to: RHOAI Dashboard → Models → qwen25-7b-instruct → Subscriptions
# Click on a subscription → Generate API Key

# Alternatively via API (if available):
# The MaaS API endpoint for key management:
echo "MaaS API: https://$(oc get route maas-api -n redhat-ods-applications -o jsonpath='{.spec.host}')"

# Test with a valid API key (replace with generated key)
curl -sk "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer <TEAM_A_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
# Expected: 200 OK with model response

# Test with invalid key — should be rejected
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer invalid-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
# Expected: HTTP 401 or 403

# Verify keys are stored hashed in PostgreSQL (not reversible)
oc exec -n maas-db statefulset/postgresql -- \
  psql -U maas -d maas -c "SELECT subscription_name, LEFT(key_hash, 20) || '...' as key_hash, status FROM api_keys LIMIT 5;"
# Expected: Hashed values, not plaintext
```

**TELL**: Keys are per-team, scoped to specific models, hashed at rest, and validated on every request. If a key leaks, only that team's access is compromised — and it can be revoked instantly without affecting others.

**Estimated time**: 5 minutes

---

### 2.3 Key Revocation — Immediate Effect

**TELL**: When a key needs to be revoked — whether due to a leak, personnel change, or rotation policy — it must take effect immediately. Not after a cache flush, not after a TTL expires. Immediately. The next request with that key must fail.

**SHOW**:
```bash
# Step 1: Confirm the key works
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer <TEAM_A_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Test"}],"max_tokens":5}'
# Expected: HTTP 200

# Step 2: Revoke the key (via RHOAI Dashboard → Subscription → Revoke Key)
# Or via API if available

# Step 3: Immediately retry the same key
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer <TEAM_A_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Test"}],"max_tokens":5}'
# Expected: HTTP 401 — key rejected on the very next request
```

**TELL**: Revocation is instantaneous. The gateway validates against the database on each request — there is no cache window where a revoked key could still be used. This meets the requirement for zero-downtime security response.

**Estimated time**: 3 minutes

---

### 2.4 Token-Based Rate Limiting — Burst Triggers 429

**TELL**: Request-based rate limiting is a blunt instrument — it treats a 10-token request the same as a 10,000-token request. Token-based rate limiting is model-aware: it meters actual consumption. A team that sends a few large prompts will hit their limit just as fairly as a team sending many small ones.

**SHOW**:
```bash
# Current rate limits per tier
echo "Premium (team-a): 500,000 tokens/hour"
echo "Basic (team-c):    50,000 tokens/hour"

# Burst test: send rapid requests to consume the basic tier's quota
# (Using a low max_tokens to keep demo fast, but in production,
# large prompts would consume quota faster)
for i in $(seq 1 20); do
  RESP=$(curl -sk -w "%{http_code}" -o /tmp/resp.json \
    "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
    -H "Authorization: Bearer <TEAM_C_API_KEY>" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Write a detailed essay about the history of artificial intelligence from its origins to present day, covering all major milestones."}],"max_tokens":2000}')
  echo "Request $i: HTTP $RESP"
  [ "$RESP" = "429" ] && echo "  → Rate limit hit!" && break
done
# Expected: After consuming ~50K tokens, requests return HTTP 429

# Verify premium tier is unaffected during basic tier's rate limiting
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/llm-inference/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer <TEAM_A_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
# Expected: HTTP 200 — premium tier completely unaffected
```

**TELL**: The basic tier was rate-limited at its configured threshold. Meanwhile, the premium tier continued serving normally. This is the core value: noisy-neighbor protection at the token level. One team's burst cannot degrade service for others.

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
# team-a-ml-engineering     premium   500000      1
# team-b-data-science       standard  100000      5
# team-c-app-developers     basic     50000       10

# Priority affects scheduling during contention
# Lower number = higher priority (team-a gets preference when GPUs are saturated)
```

**TELL**: Three tiers, each with independent rate limits. Priority determines scheduling order during GPU contention. This is all configured declaratively — changing a tier is a YAML edit, not a re-architecture.

**Estimated time**: 2 minutes

---

### 2.6 Usage Tracking — Per-Subscription Metrics

**TELL**: Governance without visibility is blind. Teams need to know their usage, and admins need to see consumption across the organization. RHOAI 3.4 provides per-subscription usage tracking queryable through Prometheus and visible in the admin dashboard.

**SHOW**:
```bash
# ServiceMonitors are scraping governance components
oc get servicemonitors -n kuadrant-system
# Expected: authorino-metrics, limitador-metrics

# Query Prometheus for rate limit counters per subscription
# (via OpenShift Console → Observe → Metrics)
echo "PromQL: rate(limitador_requests_total{namespace='models-as-a-service'}[5m])"
echo "PromQL: limitador_counter_value{namespace='models-as-a-service'}"

# Query auth decisions
echo "PromQL: rate(auth_server_authconfig_total[5m])"

# View the dashboard
echo "OpenShift Console → Observe → Dashboards → AI Gateway - Multi-Tenant Inference"
```

Navigate to OpenShift Console → Observe → Dashboards and show:
- Authorized calls by subscription
- Token rate limit counters
- vLLM throughput and TTFT
- Auth allow/deny rates

**TELL**: Every request is metered. Admins see per-subscription token consumption in real time. This data feeds into chargeback models and capacity planning — no custom instrumentation required.

**Estimated time**: 4 minutes

---

## 3. ENTERPRISE INTEGRATION (Stage C)

### 3.1 OIDC/SSO Federation

**TELL**: API keys work for programmatic access. But human operators — admins managing subscriptions, engineers browsing the model catalog — should authenticate through the enterprise identity provider. The AI Bridge federates with any OIDC-compliant IdP: the same SSO experience used for other internal tools.

**SHOW**:
```bash
# AuthConfig validates JWTs from the enterprise IdP
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

**TELL**: The AI Bridge validates tokens from the enterprise IdP on every request. This means the same identity that logs into internal tools is the identity that accesses models — unified audit trail, unified access policies.

**Estimated time**: 4 minutes

---

### 3.2 Role-Based Access Control

**TELL**: Not everyone should have the same permissions. An AI Engineer should be able to use models and view their own usage. An AI Admin should be able to create subscriptions, manage keys, and see all usage. RBAC is enforced at the gateway level based on JWT roles.

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

**TELL**: Authentication answers "who are you?" Authorization answers "what can you do?" The AI Bridge enforces both. Role assignments are managed in the IdP, not duplicated in the AI platform.

**Estimated time**: 3 minutes

---

### 3.3 Secret Rotation — Vault + ESO, Zero Downtime

**TELL**: Credentials need to rotate. Database passwords expire, API keys get compromised, compliance requires periodic rotation. The AI Bridge integrates with HashiCorp Vault via the External Secrets Operator. Secrets rotate in Vault, and within 30 seconds, all consuming workloads have the new value — no pod restarts, no manual intervention.

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

**TELL**: Governance without observability is incomplete. Operators need to see: Who is using what? Are rate limits being hit? What is the inference latency? The AI Bridge exposes all of this through standard Prometheus metrics and pre-built dashboards.

**SHOW**:
```bash
# User workload monitoring is enabled
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}'
# Expected: enableUserWorkload: true

# Dashboard is deployed
oc get configmap ai-gateway-dashboard -n openshift-config-managed \
  -o jsonpath='{.data}' | python3 -c "import json,sys;d=json.load(sys.stdin);print(list(d.keys())[0])"
# Expected: ai-gateway-inference.json

# Key metrics available:
echo "=== Key PromQL Queries ==="
echo "1. Auth decisions:       rate(auth_server_authconfig_total[5m])"
echo "2. Rate limit counters:  limitador_counter_value"
echo "3. Token throughput:     rate(vllm:generation_tokens_total[5m])"
echo "4. Time to First Token:  histogram_quantile(0.95, rate(vllm:time_to_first_token_seconds_bucket[5m]))"
echo "5. Error rate:           rate(envoy_cluster_upstream_rq_xx{envoy_response_code_class=~'4|5'}[5m])"
```

Navigate to OpenShift Console → Observe → Dashboards and walk through each panel.

**TELL**: Eight dashboard panels covering auth decisions, rate limit hits, vLLM performance, GPU utilization, queue depth, and error rates. All per-subscription where applicable. This is the same Prometheus stack already deployed — no additional infrastructure.

**Estimated time**: 4 minutes

---

## 4. BONUS CAPABILITIES (Beyond PoC Scope)

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

**TELL**: In production, the AI Bridge gateway may run on a separate CPU cluster while models run on GPU clusters across sites. This demo shows multi-cluster routing where the gateway validates OIDC tokens locally, then forwards authenticated requests to a remote model endpoint via TLS.

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
echo "├── profiles/           ← composition (single-cluster or multi-cluster)"
echo "├── clusters/live/      ← environment overlays (Kustomize patches)"
echo "└── scripts/            ← deploy, teardown, validate"
```

**TELL**: Infrastructure as code, secrets in Vault, deployment via ArgoCD. A new environment is a new overlay directory — no manual steps, fully auditable, reproducible.

**Estimated time**: 2 minutes

---

## Demo Closing

**TELL**: What we demonstrated today:

1. **Foundation**: RHOAI 3.4 with MaaS enabled, model serving with OpenAI-compatible API, seamless integration point for existing API management
2. **Governance**: Per-team subscriptions with independent API keys, token-based rate limiting that prevents noisy neighbors, three-tier access model, real-time usage tracking
3. **Enterprise Integration**: OIDC/SSO federation with role-based access, zero-downtime secret rotation via Vault, full observability through Prometheus and dashboards

All of this is:
- **Declarative** — YAML, not scripts
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

# If rate limiting hasn't triggered, show the configuration
oc get maassubscription team-c-app-developers -n models-as-a-service -o yaml | grep -A3 tokenRateLimits

# If Vault rotation is slow, show current ExternalSecret status
oc get externalsecrets -n vault-dev -o wide
```

---

## Timing Summary

| Section | Topic | Time |
|---------|-------|------|
| 1.1 | Platform Overview | 2 min |
| 1.2 | Model Serving | 3 min |
| 1.3 | API Compatibility | 5 min |
| 1.4 | Architecture Positioning | 3 min |
| 2.1 | Subscription Model | 4 min |
| 2.2 | API Key Creation | 5 min |
| 2.3 | Key Revocation | 3 min |
| 2.4 | Rate Limiting (burst) | 5 min |
| 2.5 | Tiered Access | 2 min |
| 2.6 | Usage Tracking | 4 min |
| 3.1 | OIDC/SSO | 4 min |
| 3.2 | Role-Based Access | 3 min |
| 3.3 | Secret Rotation | 5 min |
| 3.4 | Observability | 4 min |
| 4.1 | Guardrails (bonus) | 4 min |
| 4.2 | Multi-cluster (bonus) | 3 min |
| 4.3 | GitOps (bonus) | 2 min |
| **Total** | | **~61 min** |

**For a 45-minute slot**: Skip sections 4.1–4.3 (bonus) and condense 2.5 into 2.1.
**For a 30-minute slot**: Cover 1.3, 2.1, 2.2, 2.4, 2.6, 3.1, 3.3 only (core value props).
