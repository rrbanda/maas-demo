# External API Gateway Integration

This document describes how an existing enterprise API gateway (e.g., Apigee, 3scale, Kong, AWS API Gateway) integrates with the AI Bridge.

---

## Architecture Position

```
┌─────────────────────────────────────────────────────────────────────┐
│                      External API Gateway                            │
│  (Apigee / 3scale / Kong)                                           │
│                                                                     │
│  Responsibilities:                                                  │
│  • External developer portal                                        │
│  • Organization-level API keys & OAuth                              │
│  • Global rate limiting (requests/sec per org)                       │
│  • API versioning & deprecation                                     │
│  • TLS termination for external consumers                           │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                        HTTPS + Bearer Token
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      AI Bridge (MaaS Gateway)                        │
│  (RHOAI + Kuadrant/Authorino/Limitador)                             │
│                                                                     │
│  Responsibilities:                                                  │
│  • Model-aware authentication (per-subscription API keys)           │
│  • Token-based rate limiting (per-team quotas)                       │
│  • Model routing (multi-model, multi-version)                        │
│  • Usage metering & chargeback metrics                              │
│  • Content safety guardrails                                        │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
                      Model Endpoints (GPU)
```

## Integration Pattern

### Option 1: Pass-Through (External GW → AI Bridge)

The external API gateway routes to the AI Bridge as a backend service. The AI Bridge performs its own model-aware authentication on top of whatever organization-level auth the external gateway has already validated.

**Configuration (Apigee example):**
```xml
<TargetEndpoint name="ai-bridge">
  <HTTPTargetConnection>
    <URL>https://maas-gateway.apps.cluster.example.com/llm-inference</URL>
    <SSLInfo>
      <Enabled>true</Enabled>
    </SSLInfo>
  </HTTPTargetConnection>
</TargetEndpoint>
```

**Configuration (3scale example):**
```yaml
apiVersion: capabilities.3scale.net/v1beta1
kind: Backend
metadata:
  name: ai-bridge-backend
spec:
  name: "AI Bridge"
  privateBaseURL: "https://maas-gateway.apps.cluster.example.com"
  mappingRules:
    - httpMethod: POST
      pattern: "/models-as-a-service/"
      metricMethodRef: "ai-inference-calls"
      increment: 1
```

**Configuration (Kong example):**
```yaml
services:
  - name: ai-bridge
    url: https://maas-gateway.apps.cluster.example.com
    routes:
      - name: ai-models
        paths:
          - /ai/v1
        strip_path: true
    plugins:
      - name: request-transformer
        config:
          add:
            headers:
              - "X-Forwarded-For:$(client_ip)"
```

### Option 2: Token Exchange

The external gateway obtains an OIDC token from Keycloak and passes it to the AI Bridge. This allows the AI Bridge to identify the calling team based on JWT claims.

```bash
# External gateway's service account obtains a token
TOKEN=$(curl -sk "https://${KEYCLOAK_HOST}/realms/ai-bridge/protocol/openid-connect/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=external-gateway-client" \
  -d "client_secret=${GATEWAY_CLIENT_SECRET}" \
  | jq -r '.access_token')

# Pass the token to AI Bridge
curl -sk "https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-instruct","messages":[...]}'
```

### Option 3: API Key Forwarding

The external gateway passes the per-subscription API key from the consuming application directly through to the AI Bridge.

```
Consumer App → External GW (validates org key) → AI Bridge (validates subscription key) → Model
```

This provides two layers of authentication:
1. External gateway validates the organization-level credential
2. AI Bridge validates the team-level subscription key

---

## What the External Gateway Does NOT Need to Do

| Capability | External GW | AI Bridge |
|-----------|-------------|-----------|
| Organization onboarding | Yes | No |
| Per-team subscription keys | No | Yes |
| Token-based rate limiting | No | Yes |
| Model routing | No | Yes |
| Token metering & chargeback | No | Yes |
| Content safety filtering | No | Yes |
| Request rate limiting (global) | Yes | No |
| TLS termination (external) | Yes | No |
| Developer portal | Yes | No |

---

## Endpoint Configuration

The AI Bridge exposes a single stable endpoint per model:

```
https://<MAAS_GW_HOST>/models-as-a-service/<model-name>/v1/
```

The external gateway points to this as its backend. Routes:

| Path | Purpose |
|------|---------|
| `/models-as-a-service/<model>/v1/chat/completions` | Chat inference |
| `/models-as-a-service/<model>/v1/completions` | Legacy completions |
| `/models-as-a-service/<model>/v1/models` | Model metadata |

---

## Security Considerations

1. **mTLS between gateways**: Use mutual TLS between the external gateway and AI Bridge for transport security
2. **Network policy**: Restrict AI Bridge ingress to only the external gateway's IP/CIDR
3. **Header sanitization**: External gateway should strip any spoofed `Authorization` headers before forwarding
4. **Audit correlation**: Pass `X-Request-ID` or `X-Correlation-ID` through both layers for end-to-end tracing

---

## Testing the Integration

```bash
# Simulate what the external gateway would do:
# 1. Resolve the AI Bridge endpoint
BACKEND="https://${MAAS_GW_HOST}/models-as-a-service/qwen25-7b-instruct/v1"

# 2. Forward a request with the subscription's API key
curl -sk "$BACKEND/chat/completions" \
  -H "Authorization: Bearer <SUBSCRIPTION_API_KEY>" \
  -H "Content-Type: application/json" \
  -H "X-Request-ID: $(uuidgen)" \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'

# 3. Verify in metrics that the request was tracked
# Navigate to OpenShift Console → Observe → Metrics
# Query: auth_server_authconfig_total
```
