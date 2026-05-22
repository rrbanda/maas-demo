# AI Bridge Demo — Models-as-a-Service (MaaS)

> **Product**: Models-as-a-Service (MaaS) — Red Hat OpenShift AI 3.4
> **Demo Environment**: AI Bridge pattern with centralized governance

---

## Introduction

### What is Models-as-a-Service?

Models-as-a-Service (MaaS) provides **subscription-based governance** for large language model serving in Red Hat OpenShift AI. It acts as a governance layer between users and model serving infrastructure.

**Key Capabilities:**
- Per-team API key authentication with instant revocation
- Token-based rate limiting (tokens per minute/hour)
- Tiered access with independent quotas
- Usage tracking for cost attribution
- Multi-cluster and multi-provider routing via ExternalModel

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│            Cluster 1 — AI Bridge (Centralized Governance)        │
│                                                                  │
│  Client → MaaS Gateway → Authorino → Limitador → ExternalModel  │
│                                              │           │       │
│                                              ▼           ▼       │
│                                         Cluster 2    Google      │
│                                         (vLLM+GPU)   Gemini      │
└─────────────────────────────────────────────────────────────────┘
```

All traffic enters through the MaaS Gateway on Cluster 1. The gateway validates API keys, enforces rate limits, then routes to the appropriate backend. Consumers never handle provider credentials.

---

## Personas and Responsibilities

MaaS divides responsibilities among three personas:

| Persona | Responsibilities |
|---------|------------------|
| **Cluster Administrator** | Enable MaaS in RHOAI operator, configure infrastructure, scale components |
| **AI Administrator** | Create subscriptions, authorization policies, manage quotas, monitor usage |
| **User / Developer** | Find models, generate API keys, make API calls, test in Playground |

---

## Part 1: Platform Setup (Cluster Administrator)

> **Who**: Cluster Administrator
> **Goal**: Enable MaaS and ensure infrastructure is ready

### 1.1 Enable MaaS in RHOAI

MaaS is enabled by setting `modelsAsService: Managed` in the DataScienceCluster:

```bash
oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}'
# → Managed
```

### 1.2 Verify Prerequisites

```bash
# Red Hat Connectivity Link (Kuadrant) provides auth + rate limiting
oc get kuadrant -n kuadrant-system
# → kuadrant   Ready

# MaaS Tenant anchors all configuration
oc get tenant default-tenant -n models-as-a-service
# → NAME             READY   REASON       AGE
#   default-tenant   True    Reconciled   3d

# PostgreSQL stores API key hashes
oc get pods -n redhat-ods-applications | grep maas-postgres
# → maas-postgres-*   1/1   Running
```

### 1.3 GitOps Deployment

The entire stack is deployed via ArgoCD from Git:

```bash
oc get application.argoproj.io -n openshift-gitops --no-headers | wc -l
# → 28 applications
```

**Takeaway**: Platform setup is declarative and GitOps-managed. Cluster admin enables MaaS, and the operator handles the rest.

---

## Part 2: Governance Configuration (AI Administrator)

> **Who**: AI Administrator (OpenShift AI admin)
> **Goal**: Define who can access which models with what limits

### 2.1 Create Subscriptions

Subscriptions define which groups get access to which models with specific token limits.

**Navigate**: Settings → Subscriptions

![Admin Subscriptions List](images/screenshots/05-admin-subscriptions-list.png)

**Key fields:**
- **Name**: Identifier for the subscription (e.g., `team-a-premium`)
- **Groups**: OpenShift groups that can use this subscription
- **Models**: Which models are included
- **Token Rate Limits**: Tokens per minute/hour
- **Priority**: Higher number = preferred when user belongs to multiple subscriptions

**Example subscription configuration:**

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: team-a-premium
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: "team-a"
      - name: "system:authenticated"
  modelRefs:
    - name: qwen25-7b-instruct
      namespace: models-as-a-service
      tokenRateLimits:
        - limit: 100000
          window: "1m"
  priority: 10
```

### 2.2 Subscription Detail View

Click on a subscription to view its details:

![Admin Subscription Detail](images/screenshots/06-admin-subscription-detail.png)

Shows:
- Subscription name and status
- Assigned groups
- Creation date
- Resource name (Kubernetes resource)

### 2.3 Authorization Policies

Authorization policies grant API gateway access to groups. They work together with subscriptions:
- **Subscriptions** control token limits
- **Authorization policies** grant API access

**Navigate**: Settings → Authorization policies

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: external-models-auth
  namespace: models-as-a-service
spec:
  modelRefs:
    - name: qwen25-7b-instruct
      namespace: models-as-a-service
  subjects:
    groups:
      - name: "system:authenticated"
```

### 2.4 Tiered Access Example

Three-tier model for different teams:

| Tier | Subscription | Token Limit | Priority | Use Case |
|------|-------------|-------------|----------|----------|
| Premium | `team-a-premium` | 100K/min | 10 | Production workloads |
| Standard | `team-b-standard` | 20K/min | 5 | Development |
| Basic | `team-c-basic` | 5K/min | 1 | Experimentation |

**Takeaway**: AI administrators define governance declaratively. Subscriptions and policies are Kubernetes resources that can be version-controlled and GitOps-managed.

---

## Part 3: User Experience (Developer / Data Scientist)

> **Who**: Developer, Data Scientist, Application Developer
> **Goal**: Access models, generate API keys, make API calls

### 3.1 Find Available Models

**Navigate**: Gen AI studio → AI asset endpoints

![User Models List](images/screenshots/01-user-models-list.png)

Users see all models available to them with status:
- **gemini-2-0-flash** — External model (Google Gemini)
- **gemma2-9b-fp8** — Local model on Cluster 1
- **qwen25-7b-instruct** — Remote model (Cluster 2 via ExternalModel)

### 3.2 View Endpoint and Select Subscription

Click "View" on any model to see the endpoint URL and authentication options:

![User View Endpoint](images/screenshots/02-user-view-endpoint-apikey.png)

**What you see:**
- **External API endpoint**: The URL to call (OpenAI-compatible)
- **Subscription dropdown**: Select which subscription to use
- **Generate API key** button

### 3.3 Generate an API Key

Click "Generate API key" to create a temporary (ephemeral) key:

![User API Key Generated](images/screenshots/03-user-apikey-generated.png)

**Key properties:**
- **Ephemeral keys** expire in 1 hour and don't appear in your key list
- **Persistent keys** can be created from the API Keys page
- Keys use the `sk-oai-*` prefix (OpenAI-compatible format)
- Copy immediately — the key won't be shown again

### 3.4 Manage Persistent API Keys

**Navigate**: Gen AI studio → API keys

![User API Keys List](images/screenshots/07-user-apikeys-list.png)

Users can:
- View all their persistent API keys
- See status, subscription, creation date, last used, expiration
- Create new keys with custom expiration (up to 90 days)
- Revoke keys (immediate, permanent)

### 3.5 Test Models in the Playground

**Navigate**: Gen AI studio → Playground

![User Playground](images/screenshots/08-user-playground.png)

The Playground lets users:
- Select a model and subscription
- Adjust parameters (temperature, etc.)
- Chat with the model interactively
- Copy code snippets for SDK integration

### 3.6 Make API Calls

With an API key, make standard OpenAI-compatible calls:

```bash
export MAAS_GW="ae7a90237753943bb8619a15f4c4ff3e-47983113.us-east-2.elb.amazonaws.com"
export API_KEY="sk-oai-..."

# List available models
curl -sk "https://${MAAS_GW}/models-as-a-service/qwen25-7b-instruct/v1/models" \
  -H "Authorization: Bearer ${API_KEY}"

# Chat completion
curl -sk "https://${MAAS_GW}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen25-7b-instruct",
    "messages": [{"role": "user", "content": "What is OpenShift?"}],
    "max_tokens": 50
  }'
```

**OpenAI Python SDK:**

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://<MAAS_GW>/models-as-a-service/qwen25-7b-instruct/v1",
    api_key="sk-oai-..."
)

response = client.chat.completions.create(
    model="qwen25-7b-instruct",
    messages=[{"role": "user", "content": "Hello!"}]
)
print(response.choices[0].message.content)
```

**Takeaway**: Users self-serve through the RHOAI Dashboard — browse models, select subscriptions, generate keys, and make API calls. No command-line required for basic access.

---

## Part 4: Advanced Capabilities

### 4.1 ExternalModel — Multi-Cluster Routing

The AI Bridge uses `ExternalModel` CRs to route to models running anywhere:

```bash
oc get externalmodels -n models-as-a-service
# → gemini-2-0-flash     openai   generativelanguage.googleapis.com
#   qwen25-7b-instruct   openai   qwen25-7b-inference-llm-inference.apps.<INFERENCE_CLUSTER>...
```

**Same API key, same URL pattern, different backend:**

```bash
# Cross-cluster inference (Cluster 2)
curl -sk "https://${MAAS_GW}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -d '{"model":"qwen25-7b-instruct","messages":[...]}'

# Cloud API (Google Gemini)
curl -sk "https://${MAAS_GW}/models-as-a-service/gemini-2-0-flash/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -d '{"model":"gemini-2.0-flash","messages":[...]}'
```

### 4.2 Rate Limiting in Action

When a subscription exceeds its token limit, the gateway returns HTTP 429:

```bash
# Burst test with basic tier (5000 tokens/min)
for i in 1 2 3 4 5; do
  curl -sk -w "Request $i: HTTP %{http_code}\n" \
    "https://${MAAS_GW}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
    -H "Authorization: Bearer ${BASIC_KEY}" \
    -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"<large prompt>"}]}'
done
# → Request 5: HTTP 429  ← RATE LIMITED!
```

### 4.3 Secret Rotation with Vault

Provider credentials (Gemini API key, vLLM bearer token) are stored in HashiCorp Vault and synced via External Secrets Operator:

```bash
# ExternalSecrets status
oc get externalsecrets -n models-as-a-service
# → gemini-credentials          SecretSynced   True
#   vllm-cluster2-credentials   SecretSynced   True

# Rotate in Vault
oc exec vault-pod -- vault kv put secret/vllm-cluster2-credentials api-key=ROTATED-key

# Secret updates automatically (1-hour refresh or force sync)
```

### 4.4 llm-d Inference Scheduler

**What it is:**
llm-d is the inference scheduler that provides intelligent request routing across vLLM replicas based on load, KV cache utilization, and queue depth.

**Current Status:**

| Component | Status |
|-----------|--------|
| llm-d EPP | Deployed and healthy |
| InferencePool | Configured |
| InferenceModel | Configured |
| Gateway integration | Pending (requires Gateway API Inference Extension support) |

**Why it's not in the traffic path yet:**
The OpenShift gateway controller doesn't currently support `InferencePool` as an HTTPRoute backendRef. This is expected to be resolved in a future RHOAI release.

**When llm-d matters:**
- Multiple vLLM replicas (scaling scenarios)
- KV cache-aware routing
- Intelligent load balancing beyond round-robin

**Verify llm-d health:**
```bash
oc get pods -n llm-inference -l app=llm-d-epp
oc get inferencepool -n llm-inference
oc logs -n llm-inference deployment/llm-d-epp --tail=10
```

---

## Quick Reference

### URLs

| Component | URL Pattern |
|-----------|-------------|
| RHOAI Dashboard | `https://rh-ai.apps.<CLUSTER_DOMAIN>` |
| OpenShift Console | `https://console-openshift-console.apps.<CLUSTER_DOMAIN>` |
| MaaS Gateway | `https://<MAAS_GATEWAY_HOST>` (AWS ELB or Route) |
| ArgoCD | `https://openshift-gitops-server-openshift-gitops.apps.<CLUSTER_DOMAIN>` |
| API Keys | `https://rh-ai.apps.<CLUSTER_DOMAIN>/maas/tokens` |
| Playground | `https://rh-ai.apps.<CLUSTER_DOMAIN>/gen-ai-studio/playground/models-as-a-service` |

> **Note**: Replace `<CLUSTER_DOMAIN>` and `<MAAS_GATEWAY_HOST>` with your environment values. Do not commit credentials to Git.

### Navigation Paths

| Task | Navigation | Direct URL |
|------|------------|------------|
| Find models | Gen AI studio → AI asset endpoints | `/gen-ai-studio/assets` |
| Generate API key | AI asset endpoints → View → Generate API key | — |
| Manage keys | Gen AI studio → API keys | `/maas/tokens` |
| Test model | Gen AI studio → Playground | `/gen-ai-studio/playground/models-as-a-service` |
| Admin: Subscriptions | Settings → Subscriptions | `/maas/subscriptions` |
| Admin: Auth policies | Settings → Authorization policies | `/maas/authorizationpolicies` |

### Key CLI Commands

```bash
# Check MaaS status
oc get tenant default-tenant -n models-as-a-service

# List subscriptions
oc get maassubscriptions -n models-as-a-service

# List ExternalModels
oc get externalmodels -n models-as-a-service

# Check model availability
oc get maasmodelrefs -n models-as-a-service
```

---

## Summary

| What | How | Who |
|------|-----|-----|
| Enable MaaS | `modelsAsService: Managed` in DataScienceCluster | Cluster Admin |
| Create subscriptions | Settings → Subscriptions → Create | AI Admin |
| Set token limits | MaaSSubscription spec | AI Admin |
| Find models | Gen AI studio → AI asset endpoints | User |
| Generate API key | View model → Generate API key | User |
| Make API calls | OpenAI-compatible SDK/curl | User |
| Add external backend | Create ExternalModel CR | AI Admin |

**Bottom line**: MaaS provides self-service model access with enterprise governance. Platform teams configure once; users consume without friction.
