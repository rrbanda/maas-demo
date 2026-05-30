# llm-d Deployment Reference (KServe LLMInferenceService)

This document is a complete reference for how llm-d is deployed via KServe,
based on the upstream [opendatahub-io/kserve e2e-gpt-oss sample](https://github.com/opendatahub-io/kserve/tree/odh-v3.4/docs/samples/llmisvc/e2e-gpt-oss)
(branch `odh-v3.4`). It covers the CRD hierarchy, all three deployment modes,
the full manifest inventory, and key differences from our maas-demo setup.

---

## 1. Manifest Inventory (deployment order)

| # | File | Kind | Purpose |
|---|------|------|---------|
| 1 | `hf-token-secret.yaml` | `Secret` (Opaque) | HuggingFace token for model download and tokenizer access |
| 2 | `model-pvc.yaml` | `PersistentVolumeClaim` | 256 Gi RWX volume for model weights |
| 3 | `model_weights_job.yaml` | `Job` | Downloads `RedHatAI/gpt-oss-20b` via `kserve-storage-initializer` to the PVC |
| 4 | `llmisvc_config_default.yaml` | `LLMInferenceServiceConfig` | Pod template: vLLM + EPP scheduler (default intelligent scheduling) |
| 5 | `llmisvc_config_prefix_cache.yaml` | `LLMInferenceServiceConfig` | Pod template: vLLM + EPP with precise prefix cache scorer |
| 6 | `llmisvc_config_pd_disagg.yaml` | `LLMInferenceServiceConfig` | Pod template: separate prefill/decode vLLM pods + NixlConnector |
| 7 | `inference_default.yaml` | `LLMInferenceService` | Deploys 2 vLLM replicas using config #4 |
| 8 | `inference_prefix_cache.yaml` | `LLMInferenceService` | Deploys 2 vLLM replicas using config #5 |
| 9 | `inference_pd_disaggregation.yaml` | `LLMInferenceService` | Deploys 1 decode + 2 prefill pods using config #6 |
| 10 | `gateway.yaml` | `Gateway` (Envoy) | HTTP listener on port 80 |
| 11 | `ai-gateway-route.yaml` | `AIGatewayRoute` | Routes by `x-ai-eg-model` header to InferencePool |
| 12 | `service_monitor.yaml` | `ServiceMonitor` | Prometheus scrape for vLLM + EPP metrics |
| -- | `kustomization.yaml` | Kustomize overlay | Orchestrates all of the above; namespace = `kserve-lab` |

Only one of manifests 7/8/9 should be applied at a time (they share the same
resource name `gpt-oss-20b`). The kustomization.yaml comments out 8 and 9 by
default.

---

## 2. CRD Hierarchy and Data Flow

### 2.1 The two KServe CRDs

```
LLMInferenceServiceConfig (reusable template)
  ├── spec.template        → vLLM container spec (image, args, probes, env)
  ├── spec.router.scheduler → EPP container spec (image, args, plugins)
  └── spec.prefill          → (P/D mode only) prefill container spec

LLMInferenceService (instance)
  ├── spec.model.uri        → PVC reference (e.g. pvc://gpt-oss-20b-pvc)
  ├── spec.model.name       → served model name (e.g. RedHatAI/gpt-oss-20b)
  ├── spec.replicas          → number of vLLM replicas
  ├── spec.baseRefs          → references LLMInferenceServiceConfig by name
  ├── spec.template          → resource overrides (CPU, memory, GPU)
  └── spec.prefill           → (P/D mode only) prefill replica count + resources
```

### 2.2 What KServe controller creates

When an `LLMInferenceService` is applied, the KServe controller merges the
`baseRefs` config with the instance spec and creates:

| Created Resource | API Group | Purpose |
|-----------------|-----------|---------|
| vLLM Pods (via Deployment or LeaderWorkerSet) | apps/v1 | Serve the model on port 8000 |
| EPP Pod (Deployment) | apps/v1 | llm-d-inference-scheduler for request routing |
| InferencePool | inference.networking.k8s.io/v1 | Selects vLLM pods; points to EPP via `endpointPickerRef` |
| EPP Service | v1 | Exposes EPP gRPC on port 9002, health on 9003 |
| (P/D mode) Prefill Pods | apps/v1 | Separate vLLM pods for the prefill stage |

### 2.3 Request flow

```
Client
  │
  ▼
Gateway (Envoy, port 80)
  │  AIGatewayRoute matches header x-ai-eg-model
  ▼
InferencePool (gpt-oss-20b-inference-pool)
  │  endpointPickerRef → EPP Service (gRPC port 9002)
  ▼
EPP (llm-d-inference-scheduler)
  │  Scores vLLM pods using configured plugins
  │  Returns selected pod IP via ext_proc response
  ▼
Envoy routes to selected vLLM Pod (port 8000)
  │
  ▼
vLLM serves inference (/v1/chat/completions)
```

The EPP implements the Envoy `ext_proc` (External Processing) interface. For
each request, Envoy calls EPP as an external processor. EPP evaluates all
healthy vLLM pods using its scoring plugins and returns a routing decision
(the selected pod's IP address) in the `ext_proc` response headers.

### 2.4 Template variables

The LLMInferenceServiceConfig uses Go templates resolved by the KServe controller:

| Template Expression | Resolves To |
|--------------------|-------------|
| `{{ .Spec.Model.Name }}` | The `spec.model.name` from the LLMInferenceService (e.g. `RedHatAI/gpt-oss-20b`) |
| `{{ .ObjectMeta.Name }}` | The LLMInferenceService name (e.g. `gpt-oss-20b`) |
| `{{ .ObjectMeta.Namespace }}` | The namespace (e.g. `kserve-lab`) |
| `{{ ChildName .ObjectMeta.Name "-inference-pool" }}` | Derived child resource name (e.g. `gpt-oss-20b-inference-pool`) |
| `{{ ChildName .ObjectMeta.Name "-epp-service" }}` | EPP service name (e.g. `gpt-oss-20b-epp-service`) |
| `{{ ChildName .ObjectMeta.Name "-kserve-self-signed-certs" }}` | TLS cert secret name |

---

## 3. Three Deployment Modes

### 3.1 Mode 1: Default (Intelligent Inference Scheduling)

**Config name:** `llmisvc-intelligent-inference-scheduling`

**What it does:** Routes requests to the vLLM pod with the lowest load using
default scorers (queue depth + KV cache utilization).

**vLLM args:**
```
vllm serve /mnt/models
  --served-model-name "{{ .Spec.Model.Name }}"
  --port 8000
  --disable-uvicorn-access-log
  --disable-log-requests
  $VLLM_ADDITIONAL_ARGS
```

**EPP args:**
```
--pool-name '{{ ChildName .ObjectMeta.Name `-inference-pool` }}'
--pool-namespace '{{ .ObjectMeta.Namespace }}'
--zap-encoder json
--grpc-port "9002"
--grpc-health-port "9003"
--metrics-endpoint-auth=false
--secure-serving
--cert-path /etc/ssl/certs
```

**EPP scoring plugins:** Default (queue-scorer + kv-cache-utilization-scorer).
No explicit `EndpointPickerConfig` is provided; the EPP uses built-in defaults.

**GPU requirement:** 1 GPU per replica. Default sample uses 2 replicas = 2 GPUs.

**When to use:** Standard multi-replica serving. Good starting point. No
special vLLM configuration needed.

---

### 3.2 Mode 2: Precise Prefix Cache Aware Routing

**Config name:** `llmisvc-prefix-caching`

**What it does:** Routes requests to the vLLM pod that has the most relevant
KV cache blocks already computed for the request's prompt prefix. Reduces
time-to-first-token (TTFT) for requests sharing common prefixes (e.g. system
prompts, few-shot examples).

**Additional vLLM args (beyond default):**
```
--prefix-caching-hash-algo sha256_cbor
--block-size 64
--kv_transfer_config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'
--kv-events-config "$KV_EVENTS_CONFIG"
```

**Additional vLLM environment variables:**
```yaml
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: KV_EVENTS_CONFIG
  value: |
    {
      "enable_kv_cache_events": true,
      "publisher": "zmq",
      "endpoint": "tcp://<epp-service>.<namespace>.svc.cluster.local:5557",
      "topic": "kv@$(POD_IP)@<model-name>"
    }
- name: PYTHONHASHSEED
  value: "42"
```

**EPP scoring plugins (explicit EndpointPickerConfig):**
```yaml
plugins:
  - type: single-profile-handler
  - type: precise-prefix-cache-scorer    # prefix match scoring
  - type: queue-scorer                   # queue depth
  - type: kv-cache-utilization-scorer    # KV cache %
  - type: max-score-picker               # pick highest combined score

schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: queue-scorer                  weight: 2
      - pluginRef: kv-cache-utilization-scorer   weight: 2
      - pluginRef: precise-prefix-cache-scorer   weight: 3  # heaviest
      - pluginRef: max-score-picker
```

**Additional EPP requirements:**
- ZMQ port 5557 exposed on EPP pod (receives KV cache events from vLLM)
- `HF_TOKEN` secret mounted (EPP downloads tokenizers for prefix hashing)
- `tokenizers` and `go-cache` emptyDir volumes
- TLS certs volume from `<name>-kserve-self-signed-certs` secret

**Critical alignment:** `PYTHONHASHSEED=42` must match between vLLM and EPP
(`hashSeed: "42"` in the prefix-cache-scorer config). `blockSize: 64` in the
EPP must match `--block-size 64` in vLLM. Mismatches cause the prefix index
to never find cache hits.

**GPU requirement:** Same as default (1 GPU per replica, 2 replicas = 2 GPUs).

**When to use:** Workloads with shared prompt prefixes (system prompts, RAG
contexts, few-shot templates). Provides measurable TTFT improvement when
multiple requests share long common prefixes.

---

### 3.3 Mode 3: Prefill/Decode Disaggregation (P/D)

**Config name:** `llmisvc-config-pd-disagg`

**What it does:** Separates the two phases of autoregressive inference into
dedicated GPU pools:
- **Prefill pods** process the full input prompt and generate the KV cache
- **Decode pods** perform token-by-token generation using the transferred KV cache

KV cache is transferred between prefill and decode pods via RDMA using the
NixlConnector.

**vLLM configuration (both prefill and decode):**
```yaml
env:
  - name: KSERVE_INFER_ROCE
    value: "false"
  - name: VLLM_NIXL_SIDE_CHANNEL_HOST
    valueFrom:
      fieldRef:
        fieldPath: status.podIP
  - name: VLLM_ADDITIONAL_ARGS
    value: "--kv_transfer_config '{\"kv_connector\":\"NixlConnector\",\"kv_role\":\"kv_both\"}'"
  - name: UCX_PROTO_INFO
    value: "y"
  - name: UCX_TLS
    value: "rc,sm,self,cuda_copy,cuda_ipc"
```

**Key difference from default:**
- The `LLMInferenceServiceConfig` has both `spec.template` (decode) and
  `spec.prefill` sections
- The `LLMInferenceService` also has a `spec.prefill` section with its own
  replica count and resource limits
- Decode pod liveness probes use port 8001 (not 8000)
- Prefill pods use port 8000 for both liveness and readiness

**GPU requirement:** 1 decode pod (1 GPU) + 2 prefill pods (2 GPUs) = 3 GPUs minimum.

**When to use:** High-throughput serving where prefill is the bottleneck.
Disaggregation allows scaling prefill independently of decode, improving
overall throughput when input prompts are long relative to output.

---

## 4. Container Images and Versions

| Component | Image | Version |
|-----------|-------|---------|
| vLLM (all modes) | `ghcr.io/llm-d/llm-d-cuda` | `v0.6.0` |
| EPP / Inference Scheduler | `ghcr.io/llm-d/llm-d-inference-scheduler` | `v0.7.1` |
| Storage Initializer (download job) | `kserve/kserve-storage-initializer` | `v0.17.0` |

---

## 5. Port Reference

| Port | Protocol | Component | Purpose |
|------|----------|-----------|---------|
| 8000 | HTTP | vLLM | Inference API (`/v1/chat/completions`, `/v1/models`) |
| 8001 | HTTP | vLLM (P/D decode) | Health endpoint for decode pods |
| 9002 | gRPC | EPP | ext_proc service (Envoy calls this) |
| 9003 | gRPC | EPP | Health checks (liveness + readiness) |
| 9090 | HTTP | EPP | Prometheus metrics |
| 5557 | TCP/ZMQ | EPP (prefix cache mode) | Receives KV cache events from vLLM |
| 80 | HTTP | Gateway (Envoy) | Client-facing HTTP listener |

---

## 6. Probe Configuration

| Component | Probe | Type | Port | Initial Delay | Period |
|-----------|-------|------|------|---------------|--------|
| vLLM (default/prefix) | liveness | HTTP (default) | 8000 | 1200s | default |
| vLLM (default/prefix) | readiness | HTTP (default) | 8000 | 10s | 10s |
| vLLM (P/D decode) | liveness | HTTP | 8001 | 120s | 30s |
| vLLM (P/D prefill) | liveness | HTTP | 8000 | 120s | 30s |
| vLLM (P/D prefill) | readiness | HTTP | 8000 | 10s | 10s |
| EPP (all modes) | liveness | gRPC | 9003 | default | default |
| EPP (all modes) | readiness | gRPC | 9003 | default | default |

The 1200s liveness delay for vLLM in default/prefix modes accounts for large
model loading time. The P/D mode uses 120s because the model is the same but
loaded by more specialized pods.

---

## 7. Gateway API Integration

### AIGatewayRoute (Envoy AI Gateway)

The sample uses `AIGatewayRoute` (`aigateway.envoyproxy.io/v1alpha1`), which
is specific to Envoy Gateway's AI extensions:

```yaml
spec:
  parentRefs:
    - name: ai-gateway
      kind: Gateway
      group: gateway.networking.k8s.io
  rules:
    - matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: RedHatAI/gpt-oss-20b
      backendRefs:
        - group: inference.networking.k8s.io
          kind: InferencePool
          name: gpt-oss-20b-inference-pool
      timeouts:
        request: 60s
  llmRequestCosts:
    - metadataKey: llm_input_token
      type: InputToken
    - metadataKey: llm_output_token
      type: OutputToken
    - metadataKey: llm_total_token
      type: TotalToken
```

Clients route by setting the header `x-ai-eg-model: RedHatAI/gpt-oss-20b`.
The `llmRequestCosts` section enables token-level usage tracking at the
gateway layer.

**Prerequisites:**
- Kubernetes Gateway API v1.3.0+
- Gateway API Inference Extension (GIE) v1.2.0
- Envoy Gateway v1.5.0+ with AIGatewayRoute support
- Gateway controller must support `InferencePool` as a backendRef

---

## 8. Comparison: e2e-gpt-oss Sample vs. maas-demo

| Aspect | e2e-gpt-oss Sample | maas-demo (this repo) |
|--------|-------------------|----------------------|
| **Model** | RedHatAI/gpt-oss-20b (20B params) | Qwen2.5-7B-Instruct (7B params) |
| **EPP management** | KServe-managed via `LLMInferenceServiceConfig.router.scheduler` | Standalone `Deployment` in `manifests/llm-d/deployment.yaml` |
| **EPP image** | `ghcr.io/llm-d/llm-d-inference-scheduler:v0.7.1` | `registry.redhat.io/rhoai/odh-llm-d-inference-scheduler-rhel9@sha256:bddf...` |
| **TLS** | `--secure-serving` with cert volume mounts | `--secure-serving=false` |
| **InferencePool creation** | Auto-created by KServe controller | Manually created in `manifests/llm-d/inference-pool.yaml` |
| **RBAC** | Auto-managed by KServe | Manual ServiceAccount + Role + RoleBinding in `manifests/llm-d/rbac.yaml` |
| **Gateway type** | Envoy Gateway + `AIGatewayRoute` | OpenShift Gateway (Istio) + MaaS `ExternalModel` |
| **InferencePool as backendRef** | Works (Envoy Gateway supports it) | Not yet supported by OpenShift gateway controller |
| **PVC access mode** | ReadWriteMany (256 Gi) | ReadWriteOnce (20 Gi) |
| **Prefix caching** | Available as alternate config | Not configured |
| **P/D disaggregation** | Available as alternate config | Not configured |
| **Replicas** | 2 vLLM replicas (default) | 1 vLLM replica |
| **Namespace** | `kserve-lab` | `llm-inference` (worker), `models-as-a-service` (gateway) |
| **vLLM image** | `ghcr.io/llm-d/llm-d-cuda:v0.6.0` | KServe-managed (RHOAI operator default) |
| **Traffic path** | Client → Envoy Gateway → AIGatewayRoute → InferencePool → EPP → vLLM | Client → MaaS Gateway → ExternalModel → OpenShift Route → vLLM (bypasses llm-d) |

### Why the maas-demo EPP is standalone

In the maas-demo, the EPP is deployed as a standalone Deployment because:

1. The LLMInferenceService CR on RHOAI 3.4 does not yet fully wire the
   `router.scheduler` section into a managed EPP deployment in all
   configurations
2. The OpenShift gateway controller (Istio-based) does not support
   `InferencePool` as an HTTPRoute `backendRef`, so traffic cannot flow
   through the EPP even if it were KServe-managed
3. The standalone deployment allows validating that llm-d is healthy and
   tracking pods, ready for when gateway support lands

### What changes when gateway support arrives

When the OpenShift gateway controller supports `InferencePool` backendRef:
1. The `manifests/llm-d/httproute.yaml` (currently commented out) can be enabled
2. Traffic path becomes: MaaS Gateway → HTTPRoute → InferencePool → EPP → vLLM
3. The standalone EPP deployment can be replaced by the KServe-managed version
   via `LLMInferenceServiceConfig.router.scheduler`

---

## 9. Version Matrix (Prerequisites)

| Component | Minimum Version |
|-----------|----------------|
| Kubernetes | 1.32+ |
| Cert Manager | 1.18.0+ |
| Gateway API CRDs | 1.3.0+ |
| Gateway API Inference Extension (GIE) | 1.2.0 |
| Envoy Gateway | 1.5.0+ |
| LeaderWorkerSet (multi-node) | 0.6.2+ |
| Helm | v3+ |
| GPU nodes | `nvidia.com/gpu` resource |

---

## 10. Gotchas and Common Mistakes

1. **StorageClass must support ReadWriteMany.** The PVC uses `ReadWriteMany`
   access mode because multiple vLLM pods read model weights from the same
   volume. If the default StorageClass only supports `ReadWriteOnce`, the
   second replica will stay in `Pending` state. Use NFS, CephFS, or a CSI
   driver that supports RWX.

2. **Model download can take 1 hour+.** The `gpt-oss-20b` model is ~40 GB.
   The Job has a 1-hour timeout configured. Ensure the download job completes
   before applying the LLMInferenceService or the vLLM pods will crash-loop
   with empty mount.

3. **vLLM liveness probe needs 1200s initial delay.** Large models take
   10-20 minutes to load into GPU memory. The default Kubernetes liveness
   probe timeout (30s) will kill the pod before it finishes loading. The
   sample sets `initialDelaySeconds: 1200`.

4. **PYTHONHASHSEED must match between vLLM and EPP.** In prefix cache mode,
   both vLLM (`PYTHONHASHSEED=42` env var) and EPP (`hashSeed: "42"` in
   EndpointPickerConfig) must use the same seed. Mismatches mean the EPP's
   prefix index will never match vLLM's cached blocks.

5. **Block size must match.** `--block-size 64` on vLLM must match
   `blockSize: 64` in the EPP prefix-cache-scorer. Mismatches cause the
   prefix index to be misaligned with actual KV cache blocks.

6. **ZMQ endpoint uses the EPP service DNS name.** The `KV_EVENTS_CONFIG`
   endpoint uses `tcp://<epp-service>.<namespace>.svc.cluster.local:5557`.
   If the namespace or service name doesn't match, vLLM KV events will not
   reach the EPP.

7. **P/D decode pods probe on port 8001, not 8000.** The decode container's
   liveness probe points to port 8001. This is intentional; the decode runtime
   exposes health on a separate port. Pointing probes to 8000 will cause
   false failures.

8. **Only one inference YAML at a time.** All three inference manifests
   (`inference_default.yaml`, `inference_prefix_cache.yaml`,
   `inference_pd_disaggregation.yaml`) create a resource named `gpt-oss-20b`.
   Applying multiple will conflict. The kustomization.yaml enforces this by
   commenting out all but one.

9. **EPP needs HF_TOKEN for prefix cache mode.** The EPP downloads tokenizers
   from HuggingFace to compute prefix hashes. Without `HF_TOKEN`, the
   tokenizer download fails silently and prefix scoring returns zero for all
   pods.

10. **NixlConnector requires RDMA or shared-memory transport.** The
    `kv_transfer_config` with `NixlConnector` requires nodes with RDMA
    support or at least shared-memory (`sm`) for co-located pods. The UCX_TLS
    setting `rc,sm,self,cuda_copy,cuda_ipc` enables fallback transports, but
    performance degrades without RDMA.

---

## 11. Deployment Order (step-by-step)

```bash
# 1. Create namespace
kubectl create namespace kserve-lab

# 2. Create HuggingFace token secret
kubectl create secret generic hf-token \
  --from-literal=HF_TOKEN="$YOUR_HF_TOKEN" \
  -n kserve-lab

# 3. Create PVC for model weights
kubectl apply -f model-pvc.yaml -n kserve-lab

# 4. Download model weights (wait for completion)
kubectl apply -f model_weights_job.yaml -n kserve-lab
kubectl wait --for=condition=complete job/gpt-oss-20b-init-job \
  -n kserve-lab --timeout=1h

# 5. Apply LLMInferenceServiceConfig (choose one or all three)
kubectl apply -f llmisvc_config_default.yaml -n kserve-lab

# 6. Apply LLMInferenceService (choose ONE matching the config)
kubectl apply -f inference_default.yaml -n kserve-lab

# 7. Wait for pods
kubectl get pods -n kserve-lab -l app.kubernetes.io/name=gpt-oss-20b -w

# 8. Apply gateway + route
kubectl apply -f gateway.yaml -n kserve-lab
kubectl apply -f ai-gateway-route.yaml -n kserve-lab

# 9. (Optional) Apply ServiceMonitor for Prometheus
kubectl apply -f service_monitor.yaml -n kserve-lab

# Or use Kustomize for everything at once:
kubectl apply -k docs/samples/llmisvc/e2e-gpt-oss/ -n kserve-lab
```

---

## 12. Grafana Dashboards

| Dashboard | File | Covers |
|-----------|------|--------|
| All-in-one | `grafana/kserve-epp-all-dashboard.json` | Routing, prefix caching, P/D disagg combined |
| Routing & Load Balancing | `grafana/routing-load-balancing-dashboard.json` | Request/token distribution, idle GPU time, routing latency |
| Prefix Caching | `grafana/prefix-caching-dashboard.json` | vLLM prefix cache hit rate, EPP prefix indexer stats |
| P/D Disaggregation | `grafana/pd-disaggregation-dashboard.json` | Prefill/decode worker utilization, queue length, P/D decisions |

Import via Grafana UI: Dashboards > New > Import > upload JSON, select
Prometheus datasource.

Key metrics: `vllm:kv_cache_usage_perc`, `vllm:num_requests_running`,
`vllm:num_requests_waiting`, EPP routing latency histograms.

---

## 13. Cloned Source Reference

The upstream source is cloned at `/tmp/kserve-e2e/docs/samples/llmisvc/e2e-gpt-oss/`
from branch `odh-v3.4` of `opendatahub-io/kserve`.

```bash
git clone --depth 1 --branch odh-v3.4 --filter=blob:none --sparse \
  https://github.com/opendatahub-io/kserve.git /tmp/kserve-e2e
cd /tmp/kserve-e2e
git sparse-checkout set docs/samples/llmisvc/e2e-gpt-oss
```
