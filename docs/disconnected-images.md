# Disconnected Environment — Container Image Manifest

All container images required for the AI Bridge demo. Mirror these to your internal registry for air-gapped/disconnected deployments.

---

## Mirror Instructions

```bash
# Set your internal registry
INTERNAL_REGISTRY="registry.internal.example.com/ai-bridge"

# Mirror all images (requires skopeo)
while IFS= read -r image; do
  [[ "$image" =~ ^#.*$ ]] && continue
  [[ -z "$image" ]] && continue
  DEST="${INTERNAL_REGISTRY}/$(echo $image | sed 's|.*/||')"
  echo "Mirroring: $image → $DEST"
  skopeo copy --all "docker://$image" "docker://$DEST"
done < <(grep -v '^#' docs/disconnected-images.md | grep -E '^[a-z]')
```

Or use `oc mirror` with an ImageSetConfiguration:

```yaml
apiVersion: mirror.openshift.io/v1alpha2
kind: ImageSetConfiguration
mirror:
  additionalImages:
    - name: registry.redhat.io/rhoai/vllm-openai-rhel9:2.2
    - name: ghcr.io/llm-d/llm-d:latest
    - name: docker.io/hashicorp/vault:1.17
    - name: ghcr.io/external-secrets/external-secrets:v0.10.0
    - name: quay.io/kuadrant/authorino:v1.1.0
    - name: quay.io/kuadrant/limitador:v1.6.0
    - name: registry.redhat.io/rhel9/postgresql-15:latest
    - name: quay.io/keycloak/keycloak:26.0
```

---

## Image List

### Model Serving (Inference Cluster)

| Component | Image | Notes |
|-----------|-------|-------|
| vLLM Runtime | `registry.redhat.io/rhoai/vllm-openai-rhel9:2.2` | GPU node, requires NVIDIA driver |
| llm-d EPP | `ghcr.io/llm-d/llm-d:latest` | Endpoint Picker Plugin for InferencePool |
| KServe Controller | `registry.redhat.io/rhoai/kserve-controller:*` | Installed via RHOAI operator |
| KServe Agent | `registry.redhat.io/rhoai/kserve-agent:*` | Sidecar injected by KServe |

### MaaS Control Plane (Installed by RHOAI Operator)

| Component | Image | Notes |
|-----------|-------|-------|
| MaaS API | `registry.redhat.io/rhoai/maas-api:*` | Managed by RHOAI 3.4 |
| MaaS Controller | `registry.redhat.io/rhoai/maas-controller:*` | Managed by RHOAI 3.4 |

### Governance (Kuadrant Stack)

| Component | Image | Notes |
|-----------|-------|-------|
| Authorino | `quay.io/kuadrant/authorino:v1.1.0` | JWT/API key validation |
| Limitador | `quay.io/kuadrant/limitador:v1.6.0` | Rate limiting engine |
| Kuadrant Operator | `quay.io/kuadrant/kuadrant-operator:*` | Installed via OLM |

### Guardrails

| Component | Image | Notes |
|-----------|-------|-------|
| Guardrails Gateway | Custom build or `quay.io/rhoai/guardrails-orchestrator:*` | PII regex detector |

### Secret Management (Gateway Cluster)

| Component | Image | Notes |
|-----------|-------|-------|
| HashiCorp Vault | `docker.io/hashicorp/vault:1.17` | Dev mode for PoC |
| External Secrets Operator | `ghcr.io/external-secrets/external-secrets:v0.10.0` | Syncs secrets from Vault |

### Identity Provider

| Component | Image | Notes |
|-----------|-------|-------|
| Keycloak | `quay.io/keycloak/keycloak:26.0` | OIDC IdP for SSO federation |

### Database

| Component | Image | Notes |
|-----------|-------|-------|
| PostgreSQL | `registry.redhat.io/rhel9/postgresql-15:latest` | API key storage, usage tracking |

### AI Gateway (Multi-Cluster Profile Only)

| Component | Image | Notes |
|-----------|-------|-------|
| Istio Gateway (Envoy) | Provisioned by Sail Operator | Managed via GatewayClass |

### Observability (Built-in)

| Component | Image | Notes |
|-----------|-------|-------|
| Prometheus | Shipped with OpenShift | No additional mirror needed |
| Grafana | Shipped with OpenShift | No additional mirror needed |

---

## Notes

- Images marked with `*` are version-locked to the RHOAI 3.4 operator release. Use `oc adm catalog mirror` to mirror the full operator catalog.
- The Kuadrant stack (Authorino + Limitador) is installed via the Red Hat Connectivity Link (RHCL) operator from the `redhat-operators` catalog source.
- For production disconnected deployments, mirror the full operator catalogs:
  ```bash
  oc adm catalog mirror registry.redhat.io/redhat/redhat-operator-index:v4.17 \
    ${INTERNAL_REGISTRY}/redhat-operator-index
  ```
- GPU node images (NVIDIA driver, device plugin) are separate from this list and managed by the NVIDIA GPU Operator.

---

## ImageContentSourcePolicy (for disconnected clusters)

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: ai-bridge-mirror
spec:
  repositoryDigestMirrors:
    - mirrors:
        - registry.internal.example.com/ai-bridge/vault
      source: docker.io/hashicorp/vault
    - mirrors:
        - registry.internal.example.com/ai-bridge/external-secrets
      source: ghcr.io/external-secrets/external-secrets
    - mirrors:
        - registry.internal.example.com/ai-bridge/keycloak
      source: quay.io/keycloak/keycloak
    - mirrors:
        - registry.internal.example.com/ai-bridge/llm-d
      source: ghcr.io/llm-d/llm-d
    - mirrors:
        - registry.internal.example.com/ai-bridge/authorino
      source: quay.io/kuadrant/authorino
    - mirrors:
        - registry.internal.example.com/ai-bridge/limitador
      source: quay.io/kuadrant/limitador
```
