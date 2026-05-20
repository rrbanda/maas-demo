# AI Bridge PoC — Tell-Show-Tell Demo Narrative

> **Terminology**: "AI Bridge" is the PoC project name. The official RHOAI 3.4 product feature is **Models-as-a-Service (MaaS)**. Where this document says "AI Bridge", the product equivalent is "MaaS" or "Models-as-a-Service governance layer".

> **Format**: Each section follows TELL (why) → SHOW (how) → TELL (so what).
> **Target duration**: 45–60 minutes for full walkthrough.
> **Prerequisites**: Cluster deployed via ArgoCD from `github.com/rrbanda/maas-demo`, `config.env` populated.

> **PoC Success Criteria Mapping**:
> | Demo Section | PoC Stage | Success Criteria |
> |---|---|---|
> | 1. GitOps Foundation | Stage A | SC-A1: Declarative deployment via ArgoCD |
> | 2. Platform + Model | Stage A | SC-A2: Model available and serving inference |
> | 3. API Compatibility | Stage A | SC-A3: OpenAI-compatible endpoint |
> | 4. Multi-Tenant Subscriptions | Stage B | SC-B1: Per-team subscription isolation |
> | 5. API Key Lifecycle | Stage B | SC-B2: Key generation, rotation, revocation |
> | 6. Token-based Rate Limiting | Stage B | SC-B3: Token-level enforcement, 429 on breach |
> | 7. Observability | Stage B | SC-B4: Usage visibility via metrics |
> | 8. OIDC/SSO + RBAC | Stage C | SC-C1: Enterprise identity federation |
> | 9. Secret Rotation | Stage C | SC-C2: Zero-downtime credential rotation |
> | 11. ExternalModel (AI Bridge) | Stage C+ | SC-C3: Centralized governance over remote/external models |
> | Bonus: Guardrails | Beyond Scope | Not required for PoC success |
> | Bonus: Multi-cluster Legacy | Beyond Scope | Superseded by Section 11 |
>
> **Deployment Profile**: Multi-cluster (AI Bridge + inference worker).
> - **Cluster 1 (AI Bridge)**: RHOAI 3.4 with MaaS governance. No GPUs. Runs Tenant, Subscriptions, AuthPolicy, ExternalModel CRs. All consumer traffic enters here.
> - **Cluster 2 (Inference Worker)**: GPU cluster running vLLM (Qwen2.5-7B). Exposed via OpenShift Route. No direct consumer access — all traffic routed through the AI Bridge.
> - **External Provider**: Google Gemini 2.0 Flash, accessed via ExternalModel CR with server-side credential injection.
> - **What this demonstrates**: Centralized MaaS governance (auth, rate limiting, usage tracking) over heterogeneous backends — local, cross-cluster, and external cloud APIs — through a single gateway URL.
> - **Customer note**: Adding backends (new clusters, new providers) is an additive operation — one `ExternalModel` CR + one Secret. Zero consumer-side changes.

---

## Glossary and Key Concepts

Before the demo, ensure the audience understands these terms:

| Term | What it is | Why it matters |
|------|-----------|----------------|
| **RHOAI** | Red Hat OpenShift AI — the AI/ML platform on OpenShift | Provides the operator that installs and manages MaaS |
| **MaaS (Models-as-a-Service)** | RHOAI 3.4 governance layer for model endpoints | Turns raw GPU endpoints into managed API products |
| **Tenant** | Singleton CRD (`default-tenant`) in `models-as-a-service` namespace | Anchors the entire MaaS config: binds gateway, sets key expiration policy |
| **MaaSModelRef** | CRD that registers a deployed model for governance | Model won't be accessible via MaaS until this exists and is `Ready` |
| **MaaSSubscription** | CRD defining per-team quota (token rate limits + priority) | Each team gets isolated access with independent rate limits |
| **MaaSAuthPolicy** | CRD defining which groups/users can access which models | Controls WHO can generate API keys and call models |
| **Kuadrant** | Red Hat Connectivity Link (RHCL) — API management for K8s-native gateways | Provides the policy framework (auth + rate limiting) that MaaS builds on |
| **Authorino** | Kuadrant's auth engine | Validates API keys and JWT tokens on every request |
| **Limitador** | Kuadrant's rate limiting engine | Counts tokens per subscription, enforces limits, returns 429 |
| **TokenRateLimitPolicy** | Auto-generated CRD (by MaaS controller) | You never create this — it's generated from `MaaSSubscription.spec.tokenRateLimits` |
| **Perses Dashboard** | Built-in observability dashboard (Technology Preview) | Embedded in OpenShift AI console; shows token usage per subscription |
| **Tech Preview** | Red Hat support term: feature is functional but not production-supported | May change APIs or behavior in future releases; use at own risk |
| **Gateway API** | K8s-native API for service exposure (`gateway.networking.k8s.io`) | Successor to Ingress/Routes; required because Kuadrant policies attach to HTTPRoute, not OpenShift Routes |
| **`sk-oai-`** | API key prefix for MaaS-generated keys | Intentionally similar to OpenAI's `sk-` format for developer familiarity |

### CRD Relationship Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        YOU CREATE (declarative YAML)                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Tenant                 MaaSSubscription         MaaSAuthPolicy        │
│   (1 per cluster)        (1 per team)             (1 per model)         │
│   ┌──────────────┐       ┌──────────────────┐     ┌────────────────┐   │
│   │ gatewayRef   │       │ owner: [groups]  │     │ modelRef       │   │
│   │ maxExpDays   │       │ modelRefs:       │     │ allowedGroups  │   │
│   │              │       │   tokenRateLimits│     │                │   │
│   └──────┬───────┘       │   priority       │     └────────┬───────┘   │
│          │               └────────┬─────────┘              │           │
│          │                        │                        │           │
│   MaaSModelRef ◄──────────────────┼────────────────────────┘           │
│   (1 per model)                   │                                    │
│   ┌──────────────┐                │                                    │
│   │ model name   │                │                                    │
│   │ namespace    │                │                                    │
│   └──────────────┘                │                                    │
│                                   │                                    │
├───────────────────────────────────┼────────────────────────────────────┤
│             MaaS CONTROLLER AUTO-GENERATES (never create manually)      │
├───────────────────────────────────┼────────────────────────────────────┤
│                                   │                                    │
│                                   ▼                                    │
│   HTTPRoute              TokenRateLimitPolicy        AuthPolicy        │
│   (gateway.networking    (kuadrant.io/v1alpha1)      (kuadrant.io/     │
│    .k8s.io/v1)                                        v1beta2)         │
│   ┌──────────────┐       ┌──────────────────┐     ┌────────────────┐  │
│   │ routes /v1/* │       │ per-subscription │     │ API key        │  │
│   │ to model pod │       │ token counting   │     │ validation via │  │
│   │              │       │ via Limitador    │     │ Authorino      │  │
│   └──────────────┘       └──────────────────┘     └────────────────┘  │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘

Key rule: MaaSModelRef becomes "Ready" ONLY when:
  1. Tenant exists and is Active
  2. At least one MaaSSubscription references this model
  3. At least one MaaSAuthPolicy covers this model
  4. The model backend is reachable (local pod Running, or ExternalModel endpoint accessible)
```

---

## Pre-Demo Setup Checklist

```bash
# Source environment config
source scripts/config.env

# === Cluster 1 (AI Bridge) — all governance checks ===
oc login ${CTX_AI_BRIDGE}

# Verify all 5 MaaS CRDs are registered
oc api-resources | grep maas.opendatahub.io
# Expected: externalmodels, maasauthpolicies, maasmodelrefs, maassubscriptions, tenants

# Confirm Tenant is Active/Ready
oc get tenant default-tenant -n models-as-a-service \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
# Expected: Ready=True

# Confirm MaaS subscriptions are Active
oc get maassubscriptions -n models-as-a-service
# Expected: 3+ subscriptions, all "Active"

# Confirm ExternalModels and MaaSModelRefs are Ready
oc get externalmodel -n models-as-a-service
oc get maasmodelref -n models-as-a-service
# Expected: gemini-2-0-flash (Ready), qwen25-7b-instruct (Ready)

# Confirm MaaS gateway is Programmed
oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'
# Expected: True

# === Cluster 2 (Inference Worker) — model serving check ===
oc login ${CTX_INFERENCE}

# Confirm model pod is running with GPU
oc get pods -n llm-inference -l app.kubernetes.io/part-of=llminferenceservice
# Expected: 1/1 Running
```

---

## 1. GITOPS FOUNDATION (Stage A)

**TELL**: Everything in this demo is deployed declaratively from a Git repository. ArgoCD watches the repo and reconciles the desired state to the cluster. There are no manual `oc apply` steps in production — a Git commit IS the deployment. This means full audit trail, rollback capability, and reproducibility.

**SHOW**:
```bash
# ArgoCD applications managing the stack
oc get applications.argoproj.io -n openshift-gitops | grep maas-demo
# Expected: maas-demo-gateway (Synced/Healthy) on Cluster 1 (AI Bridge)
# On Cluster 2: maas-demo-inference (Synced/Healthy)

# Repository structure
echo "github.com/rrbanda/maas-demo"
echo "├── manifests/          ← base resources (no secrets, no env-specific values)"
echo "│   ├── model/          ← Tenant, MaaSModelRef, MaaSSubscriptions, MaaSAuthPolicy"
echo "│   ├── platform/       ← Kuadrant, observability, Vault, Keycloak"
echo "│   └── ai-gateway/     ← Multi-cluster gateway (Istio)"
echo "├── profiles/           ← composition profiles (single-cluster or multi-cluster)"
echo "├── clusters/live/      ← environment overlays (Kustomize patches)"
echo "└── scripts/            ← deploy, teardown, validate"

# Show the ArgoCD app is tracking our repo
oc get application maas-demo-inference -n openshift-gitops \
  -o jsonpath='{.spec.source.repoURL}{"\n"}{.spec.source.targetRevision}'
# Expected: https://github.com/rrbanda/maas-demo / main
```

**TELL**: Infrastructure as code, secrets in Vault (never in Git), deployment via ArgoCD. A new environment is a new Kustomize overlay — no manual steps, fully auditable, reproducible. Every change you see today was a Git commit.

**Estimated time**: 3 minutes

---

## 2. PLATFORM + MODEL (Stage A)

### 2.1 RHOAI 3.4 with MaaS Enabled (on AI Bridge — Cluster 1)

**TELL**: RHOAI 3.4 introduces Models-as-a-Service as a governance layer on top of model serving. It turns raw GPU endpoints into managed API products with authentication, rate limiting, and usage tracking. In our setup, MaaS runs on the AI Bridge cluster (Cluster 1) — a dedicated governance cluster with no GPUs. Enabling it is a single field in the `DataScienceCluster` CR.

**SHOW**:
```bash
# === All commands on Cluster 1 (AI Bridge) ===

# MaaS is enabled in the DataScienceCluster CR
oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}'
# Expected: Managed

# Platform pods are automatically provisioned (on AI Bridge, not inference cluster)
oc get pods -n redhat-ods-applications | grep maas
# Expected: maas-api-* Running, maas-controller-* Running

# The Tenant CR anchors the entire MaaS configuration
oc get tenant default-tenant -n models-as-a-service -o jsonpath='{.spec}' | python3 -m json.tool
# Expected:
# {
#   "apiKeys": { "maxExpirationDays": 90 },
#   "gatewayRef": { "name": "maas-default-gateway", "namespace": "openshift-ingress" }
# }
```

**TELL**: With one configuration change (`managementState: Managed`), RHOAI provisions the entire MaaS control plane — API server, controller, and gateway infrastructure. The `Tenant` CR is the organizational anchor: it binds MaaS to a specific gateway and sets the maximum API key expiration policy (90 days). Nothing else works until the Tenant exists and is Active.

**Estimated time**: 3 minutes

---

### 2.2 Model Deployed and Serving (on Inference Worker — Cluster 2)

**TELL**: The model runs on a separate GPU cluster (Cluster 2) — not on the AI Bridge. It is deployed using the `LLMInferenceService` CR and exposed via an OpenShift Route secured with a bearer token. On the AI Bridge (Cluster 1), an `ExternalModel` CR registers this remote model for governance, and a `MaaSModelRef` makes it available to subscriptions. The model becomes "Ready" only when governance is attached (at least one subscription + auth policy) AND the remote endpoint is reachable.

**SHOW**:
```bash
# === On Cluster 2 (Inference Worker) — where the model runs ===
oc login ${CTX_INFERENCE}

# LLMInferenceService — the model deployment CR
oc get llminferenceservice -n llm-inference
# Expected: qwen25-7b-instruct with Ready=True

# Model pod running with GPU
oc get pods -n llm-inference -l app.kubernetes.io/part-of=llminferenceservice
# Expected: qwen25-7b-instruct-kserve-* 1/1 Running

# Model exposed via Route (this is what the AI Bridge connects to)
oc get route -n llm-inference
# Expected: qwen25-7b-inference → qwen25-7b-instruct-kserve-workload-svc:8000

# === On Cluster 1 (AI Bridge) — where governance lives ===
oc login ${CTX_AI_BRIDGE}

# ExternalModel — registers the remote model
oc get externalmodel qwen25-7b-instruct -n models-as-a-service \
  -o custom-columns='NAME:.metadata.name,PROVIDER:.spec.provider,ENDPOINT:.spec.endpoint'
# Expected: endpoint = qwen25-7b-inference-llm-inference.apps.cluster-4l6x6...

# MaaSModelRef — governance wrapper, must be Ready
oc get maasmodelref qwen25-7b-instruct -n models-as-a-service \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase'
# Expected: Phase=Ready
```

**TELL**: The model runs on a dedicated GPU cluster. The AI Bridge doesn't need GPUs — it only needs the `ExternalModel` CR pointing to the model's endpoint and a credential Secret for authentication. The `MaaSModelRef` status of `Ready` proves governance is attached — consumers can now access the model through the MaaS gateway with full auth and rate limiting.

> **Why an ELB (not an OpenShift Route)?**
>
> The MaaS gateway uses the **Kubernetes Gateway API** (`gateway.networking.k8s.io`), not OpenShift Routes. This is intentional:
> - Kuadrant's `AuthPolicy` and `TokenRateLimitPolicy` attach to **HTTPRoute** resources (Gateway API). They cannot attach to OpenShift Routes.
> - RHOAI creates a `GatewayClass` (`data-science-gateway-class`) and a `Gateway` (`maas-default-gateway`) which provisions an Envoy-based data plane with its own LoadBalancer Service.
> - On AWS, that LoadBalancer gets an ELB. On-prem, it would be MetalLB or NodePort — but the Gateway API pattern is the same.
> - The MaaS controller auto-generates `HTTPRoute` resources (not OpenShift Routes) to route traffic to models.
>
> **Traffic flow**: Client → ELB → Gateway (Envoy) → HTTPRoute → AuthPolicy (Authorino) → TokenRateLimitPolicy (Limitador) → vLLM Pod

**Estimated time**: 3 minutes

---

## 3. API COMPATIBILITY (Stage A)

### 3.1 OpenAI API — Base URL Swap Only

**TELL**: The biggest adoption barrier is API compatibility. Existing applications using the OpenAI API format work with the MaaS gateway by changing only the base URL. No SDK changes, no code modifications. The API key format is `sk-oai-*` — intentionally similar to OpenAI's format for developer familiarity.

**SHOW**:
```bash
# The MaaS gateway exposes a standard OpenAI-compatible endpoint
echo "MaaS endpoint: https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1"

# Without auth → 401
curl -sk --max-time 10 -w "HTTP %{http_code}\n" -o /dev/null \
  "https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1/models"
# Expected: HTTP 401

# With invalid key → 403
curl -sk --max-time 10 -w "HTTP %{http_code}\n" -o /dev/null \
  "https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1/models" \
  -H "Authorization: Bearer sk-oai-invalid-key"
# Expected: HTTP 403

# With valid API key → standard OpenAI response
curl -sk "https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
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
    base_url="https://<MAAS_GW_HOST>/models-as-a-service/qwen25-7b-instruct/v1",
    api_key="sk-oai-..."  # MaaS-generated key
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

## 4. WHERE MAAS SITS — Architecture Positioning

**TELL**: MaaS is NOT replacing existing API management infrastructure. It complements it. An external API gateway handles external consumer onboarding and organization-level policies. The MaaS gateway handles what generic gateways cannot: model-aware authentication, per-subscription token metering, and inference-specific rate limiting.

When you create a `MaaSSubscription` + `MaaSAuthPolicy` + `MaaSModelRef`, the MaaS controller automatically generates three Kuadrant resources — you never create them manually:
1. `HTTPRoute` (gateway.networking.k8s.io/v1) — routes traffic to the model
2. `AuthPolicy` (kuadrant.io/v1beta2) — API key validation via Authorino
3. `TokenRateLimitPolicy` (kuadrant.io/v1alpha1) — per-subscription token counting via Limitador

**SHOW**:
```bash
# The MaaS gateway is a single stable URL for ALL models (local, remote, or external)
echo "MaaS Gateway: https://${MAAS_GW_HOST}/models-as-a-service/<model>/v1"

# Auto-generated HTTPRoute (created by MaaS controller from MaaSModelRef)
oc get httproutes -n models-as-a-service
# Expected: qwen25-7b-instruct, gemini-2-0-flash

# Auto-generated TokenRateLimitPolicy (created from MaaSSubscription.tokenRateLimits)
oc get tokenratelimitpolicies -n models-as-a-service
# Expected: maas-trlp-qwen25-7b-instruct, maas-trlp-gemini-2-0-flash

# Auto-generated AuthPolicy (created from MaaSAuthPolicy)
oc get authpolicies -n openshift-ingress
# Expected: gateway-default-auth, maas-default-gateway-authn
```

```
Integration pattern:
  End Users → External API GW (org policies) → MaaS Gateway (model governance) → Model (GPU)
                                                    │
                                            ┌───────┴────────┐
                                            │ Per-team keys  │
                                            │ Token metering │
                                            │ Rate limiting  │
                                            │ Usage tracking │
                                            └────────────────┘
```

**TELL**: The integration is a URL change in the external gateway's backend configuration. MaaS owns model-specific governance; the external gateway owns organization-level policies. They are complementary layers. You never manually create HTTPRoutes, AuthPolicies, or TokenRateLimitPolicies — the MaaS controller generates them from your high-level CRDs.

**Estimated time**: 4 minutes

---

## 5. MULTI-TENANT SUBSCRIPTIONS (Stage B)

**TELL**: Today, all use cases typically share a single API key per model. This creates a security blast radius — if one key leaks, all access is compromised. MaaS introduces subscriptions: each team gets its own isolated access with independent quotas. A burst from one team cannot impact another.

> **Key fields in `MaaSSubscription` (maas.opendatahub.io/v1alpha1)**:
> - `spec.owner`: Groups/users who can generate API keys for this subscription
> - `spec.modelRefs[].tokenRateLimits`: Token budget per model (REQUIRED). Format: `limit` (1–1B) + `window` (pattern: `^[1-9]\d{0,3}(s|m|h)$`)
> - `spec.priority`: Determines which subscription is selected when a user belongs to multiple groups and generates a key without specifying one. Higher number = higher priority. Does NOT affect inference scheduling.
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

**TELL**: Three teams, three tiers: premium (500K tokens/hr), standard (100K tokens/hr), basic (50K tokens/hr). Each operates independently with complete isolation. Priority (10/5/1) only affects default subscription selection during API key creation — it does NOT affect GPU scheduling or inference priority.

**Estimated time**: 4 minutes

---

## 6. API KEY LIFECYCLE (Stage B)

### 6.1 Key Creation and Scoped Access

**TELL**: Each subscription generates its own API keys. Keys use the `sk-oai-` prefix, are scoped to the models that subscription is bound to, and expire based on the organization's policy (max 90 days via Tenant CR). Keys are SHA-256 hashed in PostgreSQL and validated per-request by Authorino. No shared secrets between teams.

> **API Key Properties**:
> | Property | Value |
> |----------|-------|
> | Prefix | `sk-oai-` |
> | Expiration | 1–365 days (max set by `Tenant.spec.apiKeys.maxExpirationDays`, default 90) |
> | Storage | SHA-256 hash in PostgreSQL (connection via `maas-db-config` secret in `redhat-ods-applications`) |
> | Group snapshot | Captures user's group memberships at creation time |
> | Scope | Bound to subscription's `modelRefs` — key only works for those models |
> | Validation | Per-request by Authorino (no caching — revocation is instant) |

**SHOW**:
```bash
# API keys are generated via RHOAI Dashboard or MaaS API
# Navigate to: RHOAI Dashboard → Models → qwen25-7b-instruct → Subscriptions → Generate Key
# Key format: sk-oai-<random-alphanumeric>

# MaaS API endpoint for programmatic key management:
echo "MaaS API: https://$(oc get route maas-api-route -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo 'internal-only')"

# Test with a valid API key
curl -sk -w "\nHTTP %{http_code}\n" \
  "https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
# Expected: HTTP 200 with model response

# Test with invalid key — rejected immediately
curl -sk -w "\nHTTP %{http_code}\n" -o /dev/null \
  "https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-invalid-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
# Expected: HTTP 403
```

**TELL**: Keys are per-team, scoped to specific models, hashed at rest, and validated on every request. If a key leaks, only that team's access is compromised — revoke instantly without affecting others.

**Estimated time**: 4 minutes

---

### 6.2 Key Revocation — Immediate Effect

**TELL**: When a key needs to be revoked — due to a leak, personnel change, or rotation policy — it must take effect immediately. Not after a cache flush, not after a TTL expires. The very next request must fail.

**SHOW**:
```bash
# Step 1: Confirm the key works
curl -sk -w "\nHTTP %{http_code}\n" -o /dev/null \
  "https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Test"}],"max_tokens":5}'
# Expected: HTTP 200

# Step 2: Revoke the key
# Via RHOAI Dashboard → Subscription → Keys → Revoke
# Note: Revocation is PERMANENT — key cannot be reactivated

# Step 3: Immediately retry the same key
curl -sk -w "\nHTTP %{http_code}\n" -o /dev/null \
  "https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Test"}],"max_tokens":5}'
# Expected: HTTP 401 or 403 — rejected on the very next request
```

**TELL**: Revocation is instantaneous. Authorino validates against the database on each request — there is no cache window where a revoked key could still work.

**Estimated time**: 3 minutes

---

## 7. TOKEN-BASED RATE LIMITING (Stage B)

**TELL**: Request-based rate limiting treats a 10-token request the same as a 10,000-token request. Token-based rate limiting is model-aware: it meters actual consumption. A team sending a few large prompts hits their limit just as fairly as one sending many small requests.

> **How Token Metering Works (under the hood)**:
> 1. MaaS controller reads `tokenRateLimits` from your `MaaSSubscription`
> 2. It auto-generates a `TokenRateLimitPolicy` in the model's namespace (`llm-inference`)
> 3. Limitador intercepts inference responses and extracts `total_tokens` from the OpenAI-compatible `usage` field
> 4. Token count accumulates per-user within the subscription window
> 5. When the counter exceeds the limit, Limitador returns HTTP 429
> 6. Counter resets automatically when the time window expires

**SHOW**:
```bash
# The auto-generated TokenRateLimitPolicy (in models-as-a-service namespace on AI Bridge)
oc get tokenratelimitpolicies -n models-as-a-service
# Expected: maas-trlp-qwen25-7b-instruct

# View the policy details — shows per-subscription limits
oc get tokenratelimitpolicy maas-trlp-qwen25-7b-instruct -n models-as-a-service \
  -o jsonpath='{.spec.limits}' | python3 -c "
import json,sys
limits = json.load(sys.stdin)
for name, config in limits.items():
    rate = config['rates'][0]
    print(f'  {name}: {rate[\"limit\"]} tokens per {rate[\"window\"]}')
"
# Expected:
#   ...-team-a-ml-engineering-...: 500000 tokens per 1h
#   ...-team-b-data-science-...: 100000 tokens per 1h
#   ...-team-c-app-developers-...: 50000 tokens per 1h

# Burst test: rapid requests to consume the basic tier's quota
for i in $(seq 1 20); do
  RESP=$(curl -sk -w "%{http_code}" -o /tmp/resp.json \
    "https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
    -H "Authorization: Bearer ${TEAM_C_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Write a detailed essay about artificial intelligence history covering all major milestones."}],"max_tokens":2000}')
  echo "Request $i: HTTP $RESP"
  [ "$RESP" = "429" ] && echo "  → Rate limit hit!" && break
done
# Expected: After consuming ~50K tokens, requests return HTTP 429

# Verify premium tier is unaffected
curl -sk -w "\nHTTP %{http_code}\n" -o /dev/null \
  "https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer ${TEAM_A_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
# Expected: HTTP 200 — premium tier completely unaffected
```

**TELL**: The basic tier was rate-limited at its configured threshold. Meanwhile, the premium tier continued serving normally. Limitador counted actual tokens consumed (from the model's `usage.total_tokens` response field), not just request count. This is noisy-neighbor protection at the token level.

**Estimated time**: 5 minutes

---

## 8. OBSERVABILITY (Stage B)

**TELL**: Governance without observability is blind. Teams need to see their usage, admins need consumption visibility across the organization. RHOAI 3.4 provides per-subscription usage tracking through standard Prometheus metrics and a built-in Perses dashboard (Technology Preview) embedded in the OpenShift AI console.

> **Key Metrics** (all from Limitador, scraped via ServiceMonitor in `kuadrant-system`):
> | Metric | Meaning |
> |--------|---------|
> | `authorized_hits` | Token count for authorized requests |
> | `authorized_calls` | Request count that passed rate limiting |
> | `limited_calls` | Request count rejected with HTTP 429 |
>
> **Note**: The Perses dashboard is Technology Preview in RHOAI 3.4 — functional but not production-supported. May change in future releases.

**SHOW**:
```bash
# ServiceMonitors scraping governance components (in kuadrant-system namespace)
oc get servicemonitors -n kuadrant-system
# Expected: authorino-metrics, limitador-metrics

# User workload monitoring is enabled (prerequisite for metrics collection)
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}'
# Expected: enableUserWorkload: true

# PrometheusRule for automated alerting
oc get prometheusrule -n kuadrant-system
# Expected: ai-bridge-rate-limit-alerts

# Key PromQL queries (paste in OpenShift Console → Observe → Metrics):
echo "=== Limitador Metrics ==="
echo "1. Authorized tokens:  authorized_hits"
echo "2. Authorized calls:   authorized_calls"
echo "3. Rate-limited calls: limited_calls"
echo ""
echo "=== vLLM Inference Metrics ==="
echo "4. Token throughput:     rate(vllm:generation_tokens_total[5m])"
echo "5. Time to First Token:  histogram_quantile(0.95, rate(vllm:time_to_first_token_seconds_bucket[5m]))"
```

Navigate to: **OpenShift Console → Observe → Metrics** and query `authorized_calls` or `limited_calls` to see per-subscription data.

**TELL**: Every request is metered. Admins see per-subscription token consumption in real time. The same metrics power the PrometheusRule alerts (rate limit approaching, rate limited, high auth denial rate). No custom instrumentation required — it's all auto-generated from the governance CRDs.

**Estimated time**: 4 minutes

---

## 9. OIDC/SSO + RBAC (Stage C)

**TELL**: API keys work for programmatic access. But human operators — admins managing subscriptions, engineers browsing the model catalog — should authenticate through the enterprise identity provider. MaaS supports dual authentication: API keys for automation, OIDC/JWT for humans. The same identity that logs into internal tools is the identity that accesses models.

> **Dual Authentication Model**:
> 1. **API Keys** (`sk-oai-*`): Validated by Authorino against PostgreSQL. For programmatic/automated access.
> 2. **OIDC/JWT Tokens**: Validated against the IdP's JWKS endpoint. For interactive/human access and dashboard login.

**SHOW**:
```bash
# Keycloak is the OIDC provider (realm: ai-bridge)
KEYCLOAK_HOST="keycloak-keycloak.apps.cluster-6crhb.6crhb.sandbox1011.opentlc.com"
echo "OIDC Issuer: https://${KEYCLOAK_HOST}/realms/ai-bridge"

# Get a token via client credentials flow
TOKEN=$(curl -sk -X POST \
  "https://${KEYCLOAK_HOST}/realms/ai-bridge/protocol/openid-connect/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=ai-bridge-gateway" \
  -d "client_secret=ai-bridge-secret-2026" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
echo "Token obtained (${#TOKEN} chars)"

# Decode the JWT to show claims (add padding for base64url)
echo "$TOKEN" | cut -d. -f2 | python3 -c "
import sys,base64,json
p=sys.stdin.read().strip()
p+='='*(4-len(p)%4)
d=json.loads(base64.urlsafe_b64decode(p))
for k in ['iss','sub','azp','scope']:
    if k in d: print(f'  {k}: {d[k]}')
"
# Shows: iss (Keycloak issuer), sub (service account ID), azp (client ID), scope

# The RHOAI Dashboard also accepts OIDC login for admin operations
# Navigate to: RHOAI Dashboard → Login → Select SSO provider
```

**TELL**: The MaaS gateway validates tokens from the enterprise IdP on every request. This means unified audit trail — the same identity that logs into internal tools is the identity that accesses models. Role assignments are managed in the IdP, not duplicated in the AI platform.

**Estimated time**: 4 minutes

---

## 10. SECRET ROTATION — Vault + ESO (Stage C)

**TELL**: Credentials need to rotate. Database passwords expire, API keys get compromised, compliance requires periodic rotation. The platform integrates with HashiCorp Vault via the External Secrets Operator. Secrets rotate in Vault, and within 30 seconds, all consuming workloads have the new value — no pod restarts, no manual intervention.

**SHOW** (on gateway cluster):
```bash
# SecretStore is healthy (Vault connection validated)
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

## 11. EXTERNAL MODELS — AI Bridge as Centralized Gateway (Stage C+)

**TELL**: In this demo, the AI Bridge cluster (Cluster 1) runs no models — it is purely a governance layer. All models run elsewhere: vLLM on a separate GPU cluster (Cluster 2), and Gemini on Google's cloud. The `ExternalModel` CR (Technology Preview in 3.4, GA in 3.5) registers any OpenAI-compatible endpoint as a governed model. The AI Bridge handles authentication, rate limiting, and credential injection — then routes to the appropriate backend. The consumer experience is identical regardless of where the model runs: same MaaS gateway URL, same API keys, same rate limiting. They never know if the model is on a remote cluster or a third-party API.

> **ExternalModel CR fields** (`maas.opendatahub.io/v1alpha1`):
> | Field | Purpose |
> |-------|---------|
> | `spec.provider` | Provider type (e.g., `openai`) — determines API translation behavior |
> | `spec.endpoint` | Backend hostname (no scheme) — where traffic is forwarded |
> | `spec.targetModel` | Model name sent to the backend (may differ from MaaS model name) |
> | `spec.credentialRef.name` | Secret containing the provider API key (injected server-side) |
>
> **Critical detail**: The Secret referenced by `credentialRef` MUST have the label `inference.networking.k8s.io/bbr-managed: "true"` or the credential injection plugin will not find it.

**SHOW**:
```bash
# Two ExternalModels configured on the AI Bridge (Cluster 1):
oc get externalmodel -n models-as-a-service \
  -o custom-columns='NAME:.metadata.name,PROVIDER:.spec.provider,TARGET:.spec.targetModel,ENDPOINT:.spec.endpoint'
# Expected:
# NAME                 PROVIDER   TARGET               ENDPOINT
# gemini-2-0-flash     openai     gemini-2.0-flash     generativelanguage.googleapis.com
# qwen25-7b-instruct   openai     qwen25-7b-instruct   <cluster-2-inference-hostname>

# Both are registered as MaaSModelRefs and Ready
oc get maasmodelref -n models-as-a-service \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,GATEWAY:.status.gatewayRef'
# Expected: gemini-2-0-flash (Ready), qwen25-7b-instruct (Ready)

# Credentials are managed via Vault + ESO (never in Git)
oc get externalsecrets -n models-as-a-service
# Expected: gemini-credentials (SecretSynced), vllm-cluster2-credentials (SecretSynced)

# Verify the required label on synced secrets
oc get secret gemini-credentials -n models-as-a-service \
  -o jsonpath='{.metadata.labels.inference\.networking\.k8s\.io/bbr-managed}'
# Expected: true
```

### 11.1 Test: Cross-Cluster Inference (vLLM on Cluster 2)

**TELL**: This call goes through the AI Bridge on Cluster 1, which injects the bearer token and routes to Cluster 2's vLLM — a completely different OpenShift cluster. The consumer doesn't know the model is remote.

**SHOW**:
```bash
# Call the remote vLLM model through the AI Bridge gateway
curl -sk "https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen25-7b-instruct",
    "messages": [{"role": "user", "content": "What is Kubernetes in one sentence?"}],
    "max_tokens": 50
  }' | python3 -m json.tool
# Expected: Standard OpenAI chat completion response
# The request traversed: Client → AI Bridge (Cluster 1) → credential injection → Cluster 2 vLLM

# Verify the same rate limiting applies
# (ExternalModels are bound to the same MaaSSubscriptions — same governance applies)
oc get tokenratelimitpolicies -n models-as-a-service --no-headers
```

### 11.2 Test: External Provider (Google Gemini)

**TELL**: Same pattern, different backend. This call goes to Google's Gemini API. The AI Bridge injects the Gemini API key server-side — the consumer never sees or handles provider credentials. Governance (auth, rate limits, usage tracking) applies identically.

**SHOW**:
```bash
# Call Gemini through the AI Bridge — identical consumer experience
curl -sk "https://${MAAS_GW_HOST}/models-as-a-service/gemini-2-0-flash/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-2-0-flash",
    "messages": [{"role": "user", "content": "Explain rate limiting in 2 sentences."}],
    "max_tokens": 100
  }' | python3 -m json.tool
# Expected: Gemini response in OpenAI format
# The request traversed: Client → AI Bridge → path rewrite → credential injection → Google API

# The consumer used the SAME API key, SAME gateway, SAME format
# They don't know (or care) that this model is Gemini vs self-hosted vLLM on Cluster 2
```

### 11.3 Architecture: What This Proves

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        AI BRIDGE (Cluster 1)                                 │
│              MaaS Governance — No GPUs, No Models Running                    │
│                                                                             │
│  ┌───────────────┐     ┌──────────────┐     ┌────────────────────┐         │
│  │ MaaS Gateway  │────▶│  Authorino   │────▶│  Limitador         │         │
│  │ (Envoy + ELB) │     │  (API keys)  │     │  (token counting)  │         │
│  └───────┬───────┘     └──────────────┘     └────────────────────┘         │
│          │                                                                   │
│          ├── ExternalModel: qwen25-7b-instruct ──▶ Cluster 2 (vLLM + GPU)  │
│          │      credentialRef → vllm-cluster2-credentials (from Vault)       │
│          │                                                                   │
│          ├── ExternalModel: gemini-2-0-flash ────▶ Google Gemini API        │
│          │      credentialRef → gemini-credentials (from Vault)              │
│          │                                                                   │
│          └── (future) ExternalModel: llama-3-70b ─▶ Cluster 3 (Worker 2)   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

Key points:
• Single MaaS gateway = single URL for consumers
• Provider credentials injected server-side (consumers never see them)
• Same subscriptions, same rate limits, same API keys — regardless of backend
• Adding a new backend = one ExternalModel CR + one Secret (zero consumer changes)
```

**TELL**: This is the AI Bridge vision: centralized model governance across any backend. Self-hosted models on GPU clusters, third-party cloud APIs — all unified under one gateway with consistent authentication, rate limiting, and usage tracking. Adding a new model backend is a single `ExternalModel` CR + one Secret. Consumers get one stable URL and one API key that works across everything.

**Estimated time**: 8 minutes

---

## 12. BONUS CAPABILITIES (Beyond PoC Scope)

> **Note**: The following sections demonstrate additional capabilities that are NOT required for PoC success criteria validation. They are included as forward-looking differentiators.

### 12.1 Guardrails — PII Regex Detection

**TELL**: Content safety is a growing concern. While full LLM-based content analysis is on the roadmap, the architecture for inline guardrails is available today. This shows a regex-based PII detector that inspects requests before they reach the model.

**SHOW**:
```bash
# Guardrails pod: gateway + orchestrator containers
oc get pods -n ai-guardrails
# Expected: guardrails-gateway-* 2/2 Running

# Passthrough route (no filtering)
curl -sk "http://${GUARDRAILS_HOST}/passthrough/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":20}' \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['choices'][0]['message']['content'])"
# Expected: Normal model response

# PII detection route
curl -sk "http://${GUARDRAILS_HOST}/pii/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"My SSN is 123-45-6789 and email is test@example.com"}],"max_tokens":50}' \
  | python3 -m json.tool
# Expected: Response with detections field populated (PII patterns found)
```

**TELL**: The guardrails gateway inspects traffic inline without changing the model. Today it uses regex; the same architecture supports LLM-based detectors (TrustyAI) as they mature.

**Estimated time**: 4 minutes

---

### 12.2 Multi-Cluster Routing — Legacy Istio Approach (SUPERSEDED by Section 11)

> **This section is superseded.** The ExternalModel approach in Section 11 is the recommended multi-cluster pattern — it routes through MaaS governance (auth + rate limiting). This legacy Istio approach bypasses MaaS entirely and is preserved only for historical reference.

**TELL**: This was an earlier proof-of-mechanism using a custom Istio gateway. A dedicated gateway cluster validates OIDC tokens via Istio + Kuadrant AuthPolicy, then forwards to the inference cluster. Unlike Section 11, this does NOT pass through MaaS governance — no subscription-based rate limiting or API key auth.

> **Technical reality (be honest with the customer)**:
> - Routing is a hardcoded `ServiceEntry` (manual hostname of inference cluster)
> - No dynamic service discovery or fleet management
> - MaaS governance (subscriptions, rate limits) lives on the inference cluster, not this gateway
> - Auth at the gateway (OIDC/JWT) is INDEPENDENT of MaaS auth (API keys) — two separate layers
> - This is 1:1 gateway→inference, not fan-out to multiple backends
> - Final topology design requires customer's actual target architecture

**SHOW** (on gateway cluster):
```bash
# Gateway cluster components:
oc get gateway -n ai-gateway
# Expected: ai-inference-gateway (Programmed=True, with ELB address)

oc get authpolicy -n ai-gateway
# Expected: ai-gateway-oidc-auth

# Unauthenticated request → 401 (Kuadrant AuthPolicy rejects)
AI_GW_HOST="a394f738adad5408e88b1cca557b6666-1772410415.us-east-2.elb.amazonaws.com"
curl -s --max-time 10 -w "HTTP %{http_code}\n" -o /dev/null \
  "http://${AI_GW_HOST}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hi"}],"max_tokens":5}'
# Expected: HTTP 401

# Authenticated request → gateway validates JWT → routes to inference cluster
KEYCLOAK_HOST="keycloak-keycloak.apps.cluster-6crhb.6crhb.sandbox1011.opentlc.com"
TOKEN=$(curl -sk -X POST \
  "https://${KEYCLOAK_HOST}/realms/ai-bridge/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=ai-bridge-gateway&client_secret=ai-bridge-secret-2026" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

curl -s --max-time 15 "http://${AI_GW_HOST}/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hi"}],"max_tokens":10}' \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['choices'][0]['message']['content'])"
# Expected: Model response (traversed: client → ELB → Istio GW → ServiceEntry → inference cluster → vLLM)
```

**TELL**: This proves the mechanism: OIDC-authenticated cross-cluster routing via Istio. The gateway cluster has no GPUs (routing/auth only), the inference cluster has GPUs but no direct external exposure. The production topology — how many clusters, where governance lives, active-active vs ingress-fan-out — depends on the customer's target architecture and is a design exercise for the next phase.

**Estimated time**: 3 minutes

---

## Demo Closing

**TELL**: What we demonstrated today:

1. **Foundation**: GitOps-deployed, RHOAI 3.4 with MaaS enabled (5 CRDs, Tenant anchor, auto-generated gateway policies), OpenAI-compatible API
2. **Governance**: Per-team subscriptions with independent API keys (`sk-oai-`), token-based rate limiting (Limitador counting `total_tokens`), instant revocation
3. **Enterprise**: OIDC/SSO federation, zero-downtime secret rotation via Vault, per-subscription observability metrics

All of this is:
- **Declarative** — YAML CRDs, controller-reconciled
- **GitOps-managed** — auditable, reproducible, rollback-capable
- **API-compatible** — existing applications need only a base URL change
- **Complementary** — works alongside existing API management infrastructure

---

## Fallback Commands

If something fails during the live demo:

```bash
# === On Cluster 2 (Inference Worker) ===
# If model isn't responding externally, test vLLM directly
oc port-forward -n llm-inference svc/qwen25-7b-instruct-kserve-workload-svc 8443:8000 &
sleep 2
curl -sk https://localhost:8443/v1/models
kill %1

# === On Cluster 1 (AI Bridge) ===
# If MaaS gateway isn't accessible externally, test via internal service
oc port-forward -n openshift-ingress svc/maas-default-gateway-data-science-gateway-class 9443:443 &
sleep 2
curl -sk https://localhost:9443/models-as-a-service/qwen25-7b-instruct/v1/models \
  -H "Authorization: Bearer ${API_KEY}"
kill %1

# If rate limiting hasn't triggered, show the auto-generated policy
oc get tokenratelimitpolicy maas-trlp-qwen25-7b-instruct -n models-as-a-service -o yaml

# If subscriptions aren't Active, check Tenant status first
oc get tenant default-tenant -n models-as-a-service -o yaml

# If MaaSModelRef isn't Ready, check conditions
oc get maasmodelref qwen25-7b-instruct -n models-as-a-service \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool

# If ExternalModel credentials aren't injecting, check the label
oc get secret gemini-credentials -n models-as-a-service \
  -o jsonpath='{.metadata.labels.inference\.networking\.k8s\.io/bbr-managed}'
# Must be "true"

# If Vault rotation is slow, check ExternalSecret status
oc get externalsecrets -n models-as-a-service -o wide
```

---

## Timing Summary

| Section | Topic | Time |
|---------|-------|------|
| 1 | GitOps Foundation | 3 min |
| 2.1 | Platform Overview + Tenant | 3 min |
| 2.2 | Model Serving + MaaSModelRef | 3 min |
| 3 | API Compatibility | 5 min |
| 4 | Architecture Positioning | 4 min |
| 5 | Multi-Tenant Subscriptions | 4 min |
| 6.1 | API Key Creation | 4 min |
| 6.2 | Key Revocation | 3 min |
| 7 | Token Rate Limiting | 5 min |
| 8 | Observability | 4 min |
| 9 | OIDC/SSO + RBAC | 4 min |
| 10 | Secret Rotation | 5 min |
| 11 | ExternalModel — AI Bridge Gateway | 8 min |
| 12.1 | Guardrails (bonus) | 4 min |
| 12.2 | Multi-cluster legacy (bonus) | 3 min |
| **Total** | | **~62 min** |

**For a 60-minute slot**: Skip sections 12.1–12.2 (bonus).
**For a 45-minute slot**: Skip 12.1–12.2, condense section 4 into section 2, abbreviate section 11 (show one ExternalModel call only).
**For a 30-minute slot**: Cover 1, 2, 3, 5, 6.1, 7, 11.2 (Gemini call) only — shows core governance + external model story.

---

## Appendix: Prerequisites (from RHOAI 3.4 docs)

| Requirement | Detail |
|-------------|--------|
| OpenShift | 4.19.9+ |
| RHOAI Operator | 3.4+ (channel: `stable-3.4`) |
| Red Hat Connectivity Link (RHCL) | 1.2+ (provides Kuadrant/Authorino/Limitador) |
| `Kuadrant` CR | In `kuadrant-system` with Ready status |
| `GatewayClass` | `data-science-gateway-class` (created by RHOAI) |
| User Workload Monitoring | Enabled in `cluster-monitoring-config` |
| PostgreSQL | For API key hash storage (`maas-db-config` secret in `redhat-ods-applications`) |
| NVIDIA GPU Operator | For GPU nodes |
