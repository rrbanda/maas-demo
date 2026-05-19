# AI Bridge (MaaS) Demo — Red Hat OpenShift AI 3.4

Demonstration of **Models-as-a-Service** (MaaS) governance capabilities on Red Hat OpenShift AI (RHOAI) 3.4. This repository provides manifests, scripts, and documentation to deploy and validate centralized model governance, multi-cluster routing, enterprise identity federation, content safety guardrails, and observability.

## What This Demonstrates

| Capability | Description |
|-----------|-------------|
| Per-use-case authentication | API keys scoped to teams/models via MaaSSubscription |
| Token-based rate limiting | Per-subscription token limits (tokens/hour) via Limitador |
| Tiered access | Premium / Standard / Basic tiers with independent policies |
| Usage tracking | Per-subscription metrics via Prometheus + ServiceMonitors |
| OIDC/SSO federation | Any OIDC IdP JWT validation alongside API keys (BYO Keycloak/Okta/Azure AD) |
| Secret rotation pattern | Vault + External Secrets Operator demonstrating zero-downtime K8s Secret sync |
| Content safety guardrails | PII detection (email, SSN, credit card regex) before model access |
| Multi-cluster routing | Istio gateway on CPU cluster → model route on remote GPU cluster |

---

## Architecture

```mermaid
flowchart TB
    subgraph GW["Gateway Cluster — optional"]
        direction TB
        AIGw["AI Gateway<br/>(Istio + Gateway API)"]
        Vault["HashiCorp Vault<br/>+ ESO"]
    end

    subgraph INF["Inference Cluster"]
        direction TB
        MaaS["MaaS Gateway<br/>(Envoy + Authorino + Limitador)<br/>created by RHOAI operator"]
        Guard["Guardrails Gateway<br/>(PII Detection)"]
        EPP["llm-d EPP<br/>(Endpoint Picker)"]
        vLLM["vLLM<br/>(Qwen2.5-7B-Instruct)"]
        PG["PostgreSQL<br/>(MaaS state)"]
        Prom["Prometheus<br/>(User Workload Monitoring)"]
        OIDC["OIDC AuthConfig<br/>(validates JWT from external IdP)"]
    end

    Client(["API Consumer"]) --> MaaS
    Client -->|"multi-cluster path"| AIGw
    AIGw -->|"TLS origination<br/>to model route"| vLLM
    MaaS -->|"auth + rate limit"| vLLM
    Guard -->|"PII filter proxy"| vLLM
    EPP -.->|"routes to optimal replica"| vLLM
    OIDC -.->|"validates tokens"| MaaS
    MaaS -.-> Prom
    Vault -.->|"syncs secrets to K8s"| Vault
```

### Multi-Cluster Traffic Flow

The AI Gateway routes directly to the model's OpenShift Route on the inference cluster. This provides a single entry point on the gateway cluster but does **not** pass through MaaS auth (that is a separate direct-access path).

```mermaid
sequenceDiagram
    participant C as Client
    participant GW as AI Gateway<br/>(Gateway Cluster)
    participant RT as OpenShift Route<br/>(Inference Cluster)
    participant V as vLLM

    C->>GW: POST /v1/chat/completions
    GW->>GW: Host header rewrite
    GW->>RT: TLS origination (port 443)
    RT->>V: Route to vLLM pod
    V->>GW: Response
    GW->>C: Response
```

### Governance Stack (MaaS Direct Access)

When clients access the MaaS gateway directly, requests pass through Authorino (auth) and Limitador (rate limiting):

```mermaid
flowchart LR
    subgraph AuthZ["Authentication"]
        AK["API Keys<br/>(MaaSSubscription)"]
        OIDC["OIDC JWT<br/>(external IdP)"]
    end

    subgraph RL["Rate Limiting"]
        TRL["Token Rate Limits<br/>(tokens/hour per subscription)"]
        LIM["Limitador<br/>(enforcement)"]
    end

    subgraph OBS["Observability"]
        SM["ServiceMonitors"]
        PROM["Prometheus"]
        DASH["Dashboard ConfigMap"]
    end

    AK --> LIM
    OIDC --> LIM
    TRL --> LIM
    LIM --> SM
    SM --> PROM
    PROM --> DASH
```

---

## Prerequisites

These must be installed on your cluster(s) **before** running `deploy-all.sh`:

| Prerequisite | Required for | Installed by this repo? |
|--------------|-------------|------------------------|
| OpenShift 4.19+ | Platform | No |
| RHOAI 3.4 operator | MaaS gateway, model serving | No (DSC manifest only) |
| RHCL/Kuadrant operator | Authorino + Limitador | No |
| NVIDIA GPU Operator | Model inference (both clusters have GPUs) | No |
| Istio/Service Mesh | Multi-cluster routing | No |
| OIDC provider (Keycloak, Okta, etc.) | OIDC demo | No — bring your own |

The scripts deploy the **application-level** resources (model, subscriptions, guardrails, Vault, ESO, observability) but assume the platform operators are already present.

---

## Quick Start

### 0. Platform Setup (one-time)

Ensure the following operators are installed on your inference cluster:
- Red Hat OpenShift AI 3.4
- Red Hat Connectivity Link (Kuadrant)
- NVIDIA GPU Operator

For multi-cluster, also install Istio/Service Mesh on the gateway cluster.

### 1. Configure

```bash
cp scripts/config.env.example scripts/config.env
# Edit config.env with your cluster details — all REPLACE_WITH_* values must be filled
vim scripts/config.env
```

Key values to fill:
- `CTX_INFERENCE` / `CTX_GATEWAY` — your `oc` context names
- `REMOTE_MODEL_HOSTNAME` — the model's OpenShift Route hostname (for multi-cluster)
- `VLLM_SERVICE` — the KServe workload service (e.g., `qwen25-7b-instruct-kserve-workload-svc.llm-inference.svc:8000`)
- `KEYCLOAK_HOST` — your OIDC provider hostname (if using OIDC)

### 2. Deploy

```bash
./scripts/deploy-all.sh
```

### 3. Validate

```bash
./scripts/validate-poc.sh
```

---

## Directory Structure

```
maas-demo/
├── README.md                              # This file
├── docs/
│   ├── architecture.md                    # Detailed technical architecture
│   ├── poc-validation.md                  # PoC success criteria alignment
│   └── gaps-and-considerations.md         # Production vs demo differences
├── manifests/
│   ├── platform/                          # Platform-level resources
│   │   ├── rhoai-instance/               # DataScienceCluster with MaaS enabled
│   │   ├── maas-postgres/                # PostgreSQL (MaaS state store)
│   │   ├── monitoring-config/            # User workload monitoring
│   │   └── observability/                # ServiceMonitors + Dashboard
│   ├── model/                            # Model deployment + subscriptions
│   ├── llm-d/                            # Endpoint Picker Pod (intelligent routing)
│   ├── ai-gateway/                       # Multi-cluster Istio routing
│   ├── guardrails/                       # Content safety gateway (PII regex)
│   ├── oidc/                             # OIDC AuthConfig (BYO IdP)
│   └── vault-eso/                        # Vault + External Secrets (pattern demo)
├── scripts/
│   ├── config.env.example                # Configuration template
│   ├── deploy-all.sh                     # Deployment script (imperative ordering)
│   ├── validate-poc.sh                   # PoC validation (all criteria)
│   └── teardown.sh                       # Clean removal
└── profiles/                             # Kustomize overlays (for ArgoCD users)
    ├── single-cluster/
    └── multi-cluster/
```

---

## Deployment Profiles

### Single Cluster
Deploys the full stack on one OpenShift cluster. Multi-cluster routing resources are skipped.

```bash
./scripts/deploy-all.sh single-cluster
# or: ./scripts/deploy-all.sh --profile single-cluster
```

### Multi-Cluster
Deploys the gateway components on one cluster and inference on another.

```bash
./scripts/deploy-all.sh multi-cluster
# or: ./scripts/deploy-all.sh --profile multi-cluster
```

> **Note:** The `profiles/` directory provides Kustomize overlays for ArgoCD/GitOps users.
> The scripts handle ordering imperatively and are recommended for initial setup.
> Profiles contain `REPLACE_WITH_*` placeholders that must be substituted before use with `oc apply -k`.

---

## Key Endpoints (after deployment)

| Endpoint | URL Pattern | Auth | Notes |
|----------|-------------|------|-------|
| MaaS Gateway | `https://<MAAS_GW_HOST>/llm-inference/<model>/v1/chat/completions` | API key or OIDC | Created by RHOAI operator |
| Multi-cluster Gateway | `http://<AI_GW_HOST>:80/v1/chat/completions` | None | Routes directly to model (bypasses MaaS auth) |
| Guardrails (passthrough) | `http://<GUARDRAILS_HOST>/passthrough/v1/chat/completions` | None | No PII filtering |
| Guardrails (PII filter) | `http://<GUARDRAILS_HOST>/pii/v1/chat/completions` | None | Regex PII detection |

---

## PoC Success Criteria

This demo validates the AI Bridge PoC success criteria:

1. **Per-use-case auth** — MaaSSubscription CRs with per-team API keys ✅
2. **Token rate limiting** — tokens/hour limits per subscription ✅
3. **Usage tracking** — Prometheus ServiceMonitors for auth/rate-limit metrics ✅
4. **Tiered access** — 3 tiers (500K/100K/50K tokens/hr) with independent limits ✅
5. **OIDC/SSO** — AuthConfig validates JWT from external IdP ✅
6. **Observability** — Dashboard ConfigMap + ServiceMonitors ✅
7. **API compatibility** — Standard OpenAI `/v1/chat/completions` format ✅
8. **Secret rotation pattern** — Vault → ESO → K8s Secret (30s refresh) ✅

See [docs/poc-validation.md](docs/poc-validation.md) for detailed evidence and caveats.

---

## License

Apache License 2.0
