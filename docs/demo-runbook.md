# AI Bridge Demo Runbook — Wells Fargo

> **Date**: Tuesday May 26, 2026, 11am EST  
> **Format**: Tell-Show-Tell  
> **Duration**: 45 minutes  
> **Rule**: Say "AI Bridge" — NEVER "gateway"

---

## Pre-Demo Setup (run before the call)

```bash
oc login https://api.cluster-6crhb.6crhb.sandbox1011.opentlc.com:6443 --username=admin --password=MzA0NjE1NjM2 --insecure-skip-tls-verify

export MAAS_GW="ae7a90237753943bb8619a15f4c4ff3e-47983113.us-east-2.elb.amazonaws.com"
export API_KEY="sk-oai-e9lhgDa0SY5NC2VA_evZTorg6iaUNnr1Oa1QreeR0uTjgWTMCjzX8Wf9HU5e"
```

**Dashboard URL**: https://rh-ai.apps.cluster-6crhb.6crhb.sandbox1011.opentlc.com  
**Login**: admin / MzA0NjE1NjM2

---

## Act 1: Platform Foundation (5 min)

### TELL

"Models-as-a-Service — what we call the AI Bridge — is the governance layer in RHOAI 3.4. It provides subscription-based governance for LLM serving: per-team authentication, token-based rate limiting, usage tracking for cost allocation, and integration with enterprise identity providers. One configuration change enables it. The entire stack is declarative — Kubernetes custom resources managed via GitOps."

### SHOW

```bash
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}'
```
→ `Managed`

```bash
oc get tenant default-tenant -n models-as-a-service
```
→ `Ready / Reconciled`

> Say: "The Tenant is the root custom resource for all AI Bridge configuration. It's a singleton — one per cluster. It configures API key expiration limits, external OIDC authentication, telemetry, and the gateway reference. Ready means all components are provisioned."

```bash
oc get kuadrant -n kuadrant-system
```
→ Shows Kuadrant running

```bash
oc get applications.argoproj.io maas-demo-gateway -n openshift-gitops -o jsonpath='Sync: {.status.sync.status}  Health: {.status.health.status}'
```
→ `Sync: Synced  Health: Healthy`

### TELL

"With MaaS enabled, the platform automatically provisions the governance stack: Authorino validates API keys against PostgreSQL on every request. Limitador enforces token-based rate limits per subscription. The MaaS API handles key lifecycle — create, rotate, revoke. Five custom resources drive everything: Tenant configures tenant-wide settings like API key expiration and OIDC. MaaSSubscription defines per-team quotas. MaaSAuthPolicy grants gateway access. MaaSModelRef references deployed models. ExternalModel routes to external providers. All Kubernetes-native, all GitOps-compatible."

---

## Act 2: Governance Configuration (7 min)

### TELL

"In 3.4, MaaS uses a subscription-based model — this replaces the tier-based model from 3.3. Subscriptions are MaaSSubscription custom resources that define which groups get quota for which models with configurable token rate limits. Users can belong to multiple subscriptions, with priority levels determining which one applies. Subscriptions and authorization policies work together: subscriptions control token limits, auth policies grant API gateway access. Both are required for a user to access a model."

### SHOW

```bash
oc get maassubscriptions -n models-as-a-service -o custom-columns="NAME:.metadata.name,PHASE:.status.phase,PRIORITY:.spec.priority"
```
→ Shows 7 subscriptions with different priorities

```bash
oc get maassubscription team-a-premium -n models-as-a-service -o yaml | grep -A20 "spec:"
```
→ Shows models, token limits, groups

```bash
oc get maasauthpolicy -n models-as-a-service
```
→ Shows auth policies (ignore `qwen25-7b-instruct-auth Failed` — leftover from a previous model)

**Also show on Dashboard**: Settings → Subscriptions → click one for detail

### TELL

"Each team gets independent quotas. One team's burst cannot affect another. Priority levels determine the default subscription — for example, if a user belongs to both 'analytics' at priority 1 and 'production' at priority 2, creating a key without specifying a subscription selects 'production'. The MaaS controller automatically generates TokenRateLimitPolicy resources from subscriptions — you never create rate-limit policies manually."

---

## Act 3: Authentication Enforcement (5 min)

### TELL

"Every request to the AI Bridge is validated. No auth — rejected. Wrong key — rejected. The API is OpenAI-compatible. Existing code works with just a base URL change."

### SHOW

**No auth → 401:**
```bash
curl -sk -w "\nHTTP %{http_code}\n" "https://${MAAS_GW}/models-as-a-service/gemma2-9b-fp8/v1/chat/completions" -H "Content-Type: application/json" -d '{"model":"gemma2-9b-fp8","messages":[{"role":"user","content":"hi"}]}'
```

**Fake key → 403:**
```bash
curl -sk -w "\nHTTP %{http_code}\n" "https://${MAAS_GW}/models-as-a-service/gemma2-9b-fp8/v1/chat/completions" -H "Authorization: Bearer sk-oai-FAKE-KEY" -H "Content-Type: application/json" -d '{"model":"gemma2-9b-fp8","messages":[{"role":"user","content":"hi"}]}'
```

**Valid key → 200:**
```bash
curl -sk "https://${MAAS_GW}/models-as-a-service/gemma2-9b-fp8/v1/chat/completions" -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" -d '{"model":"gemma2-9b-fp8","messages":[{"role":"user","content":"What is OpenShift AI?"}],"max_tokens":50}' | python3 -m json.tool
```

### TELL

"Zero trust by default. 401 means no credentials provided. 403 means Authorino checked the key against PostgreSQL and rejected it. 200 means valid key, subscription verified, token budget checked — all before the request reaches the model. The `sk-oai-*` key format is intentionally OpenAI-compatible. Users can create permanent keys or temporary 1-hour keys. Group membership is captured at key creation time. Revocation is immediate — no cache delay."

---

## Act 4: User Self-Service (7 min)

### TELL

"Users self-serve through the RHOAI Dashboard. They discover models on the AI asset endpoints page, see their subscription and token limits, generate API keys scoped to their subscription, and test in the Playground — all without admin involvement. External OIDC users create keys via the MaaS API using their JWT token."

### SHOW (all on Dashboard UI)

1. **Gen AI Studio → AI asset endpoints** — show models list
2. Click **View** on gemma2-9b-fp8 — show endpoint URL + subscription selector
3. Click **Generate API key** — show `sk-oai-*` key (explain: shown only once)
4. **Gen AI Studio → Playground** — type a prompt, show model responding
5. **Gen AI Studio → API keys** — show key management (create, view, revoke)

### TELL

"Complete self-service. Users don't need admin help. Keys are scoped to their subscription's models and token limits. Key expiration is configurable from 1 to 365 days, with a maximum set by the Tenant CR. Revocation is permanent and immediate — applications using a revoked key get 401 instantly."

---

## Act 5: Rate Limiting (5 min)

### TELL

"Token-based rate limiting — not just request-based. Tokens are the basic units of text processing in LLMs. A 1000-token prompt consumes 100x more capacity than a 10-token prompt. MaaS enforces token limits per subscription per model, preventing large-prompt requests from consuming disproportionate capacity."

### SHOW

**Burst test — 10 simultaneous requests:**
```bash
for i in {1..10}; do curl -sk -o /dev/null -w "Request $i: HTTP %{http_code}\n" "https://${MAAS_GW}/models-as-a-service/gemma2-9b-fp8/v1/chat/completions" -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" -d "{\"model\":\"gemma2-9b-fp8\",\"messages\":[{\"role\":\"user\",\"content\":\"Quick test $i\"}],\"max_tokens\":50}" & done; wait
```

**Check response headers:**
```bash
curl -sk -D- -o /dev/null "https://${MAAS_GW}/models-as-a-service/gemma2-9b-fp8/v1/chat/completions" -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" -d '{"model":"gemma2-9b-fp8","messages":[{"role":"user","content":"hello"}],"max_tokens":10}' 2>&1 | head -15
```

### TELL

"Each subscription tier has independent limits. Premium gets 100K tokens/min, standard gets 20K, basic gets 5K. When a limit is hit, the AI Bridge returns HTTP 429 with X-RateLimit-Remaining and Retry-After headers so applications can implement exponential backoff. Other subscriptions are completely unaffected — Limitador tracks counters per subscription, not globally."

---

## Act 6: Enterprise Security (5 min)

### TELL

"No credentials in Git. No credentials in application code. Vault stores provider API keys, External Secrets Operator syncs them to Kubernetes Secrets on a schedule, and the AI Bridge's payload-processing pipeline injects them server-side into outbound requests. End users never see provider credentials."

### SHOW

```bash
oc get externalsecret -A
```
→ 4 secrets SecretSynced

```bash
oc get pods -n vault-dev --no-headers | head -1
```
→ Vault running

```bash
oc get tenant default-tenant -n models-as-a-service -o jsonpath='{.spec.externalOIDC}'
```
→ Shows Keycloak OIDC config

```bash
oc get pods -n keycloak --no-headers | grep keycloak-0
```
→ Keycloak running

### TELL

"The AI Bridge supports external OIDC authentication. Users retrieve a JWT from your identity provider, then use it to create MaaS API keys. The Tenant CR's `externalOIDC` field takes two values: `issuerUrl` and `clientId`. For Wells Fargo, point the issuer to your Okta or Azure AD. Group claims from the OIDC token map directly to MaaS subscriptions — no OpenShift user accounts required for every end user."

---

## Act 7: Observability (5 min)

### TELL

"Built-in observability via the MaaS dashboard — a Tech Preview feature in 3.4. Monitors subscription-level token consumption, request counts, and rate-limit violations. Usage data can be exported as CSV for cost attribution and showback reporting to finance teams."

### SHOW (Dashboard UI)

Navigate to: **Observe & Monitor → Dashboard**

- **Cluster tab** — overall system health, request counts
- **Models tab** — per-model metrics
- **Usage tab** — per-subscription token usage (Tech Preview)

```bash
oc exec -n redhat-ods-monitoring deployment/data-science-perses -- curl -s 'http://localhost:8080/proxy/globaldatasources/prometheus/api/v1/query?query=sum(istio_requests_total)' | python3 -c "import json,sys; print('Total requests:', json.load(sys.stdin)['data']['result'][0]['value'][1])"
```

### TELL

"This data feeds cost attribution and showback. The dashboard provides per-subscription breakdowns of total tokens, total requests, errors, success rate, and active users. Export to CSV directly from the UI. The underlying metrics are in Prometheus — you can federate to your existing monitoring stack or configure remote write for enterprise observability integration."

---

## Act 8: Guardrails (3 min — if time allows)

### TELL

"Content safety filtering for PII detection before requests reach the model."

### SHOW

```bash
oc get pods -n ai-guardrails --no-headers
```

```bash
oc exec -n ai-guardrails deployment/guardrails-gateway -- curl -s http://localhost:8090/pii/v1/chat/completions -H "Content-Type: application/json" -d '{"model":"gemma2-9b-fp8","messages":[{"role":"user","content":"My email is john@example.com and SSN is 123-45-6789"}]}' 2>/dev/null | python3 -m json.tool
```

### TELL

"Regex-based PII detection for email, SSN, credit card patterns. TrustyAI provides LLM-based jailbreak and PII detection in 3.4 via IPP plugin. Full guardrails UI is on the roadmap."

---

## If They Ask...

| Question | Answer |
|----------|--------|
| Priority requests (queue skip) | "Upcoming llm-d scheduling feature. Not in 3.4. We're tracking it." |
| vSR (semantic routing) | "Active upstream development. Not yet in the product. We'll update on availability." |
| PostgreSQL | "By design, MaaS doesn't manage PostgreSQL. Gives enterprises flexibility to use existing DB infrastructure." |
| Multi-cluster | "3.4 supports ExternalModel routing to remote clusters. Full multi-cluster HA with shared API keys is 3.5 (August)." |
| Installation timeline for CML40 | Defer to the PoC scoping doc. Don't commit to dates. |
| PDF capability dates | "Let's align on the PoC scope first. The scoping doc maps capabilities to priorities." |
