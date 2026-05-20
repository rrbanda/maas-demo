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
| Perses Dashboard | Embedded in RHOAI 3.4 console | Tech Preview, no separate deployment |

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

## Disconnected Workarounds

### Authorino WASM Plugin

In disconnected environments, Authorino's WASM-based rate limiting integration (used by Kuadrant) requires the WASM binary to be available locally. The Kuadrant operator normally fetches it from an OCI registry at runtime.

**Workaround**:
1. Pre-pull the WASM module OCI artifact and mirror it:
   ```bash
   # Mirror the Kuadrant WASM plugin to internal registry
   skopeo copy \
     docker://quay.io/kuadrant/wasm-shim:latest \
     docker://${INTERNAL_REGISTRY}/kuadrant/wasm-shim:latest
   ```
2. Configure the `WasmPlugin` resource to reference the mirrored location:
   ```yaml
   apiVersion: extensions.istio.io/v1alpha1
   kind: WasmPlugin
   metadata:
     name: kuadrant-wasm-shim
     namespace: istio-system
   spec:
     url: oci://${INTERNAL_REGISTRY}/kuadrant/wasm-shim:latest
   ```
3. If OCI-based WASM loading is not possible, use a `ConfigMap`-mounted approach:
   ```bash
   # Download the WASM binary
   skopeo copy docker://quay.io/kuadrant/wasm-shim:latest dir:///tmp/wasm-shim
   # Extract and create a ConfigMap (for small WASM files only)
   oc create configmap wasm-shim-binary -n istio-system \
     --from-file=plugin.wasm=/tmp/wasm-shim/wasm-plugin.wasm
   ```

### Artifactory as Mirror Registry

For environments using JFrog Artifactory as the container registry:

```bash
# Configure Artifactory as a Docker V2 remote repository pointing to each source
# Then reference in ImageContentSourcePolicy or ImageDigestMirrorSet (OCP 4.13+)

# For OCP 4.13+, prefer ImageDigestMirrorSet over ImageContentSourcePolicy:
cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ai-bridge-artifactory-mirror
spec:
  imageDigestMirrors:
    - mirrors:
        - artifactory.internal.example.com/docker-remote/hashicorp/vault
      source: docker.io/hashicorp/vault
    - mirrors:
        - artifactory.internal.example.com/docker-remote/external-secrets/external-secrets
      source: ghcr.io/external-secrets/external-secrets
    - mirrors:
        - artifactory.internal.example.com/docker-remote/kuadrant/authorino
      source: quay.io/kuadrant/authorino
    - mirrors:
        - artifactory.internal.example.com/docker-remote/kuadrant/limitador
      source: quay.io/kuadrant/limitador
    - mirrors:
        - artifactory.internal.example.com/docker-remote/keycloak/keycloak
      source: quay.io/keycloak/keycloak
EOF
```

### Operator Catalogs for Disconnected

Required operator catalogs to mirror:
- `registry.redhat.io/redhat/redhat-operator-index:v4.17` — RHOAI, RHCL (Kuadrant), Serverless operators
- `registry.redhat.io/redhat/certified-operator-index:v4.17` — NVIDIA GPU Operator, External Secrets Operator

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
