# Per-Subscription PromQL Queries

Pre-built queries for monitoring MaaS subscription usage in OpenShift Console → Observe → Metrics.

> **Metric sources**: Authorino (auth decisions), Limitador (rate limiting/token metering), vLLM (inference performance).
> These metrics are exposed when the MaaS controller auto-generates `TokenRateLimitPolicy` and `AuthPolicy` resources from your `MaaSSubscription` and `MaaSAuthPolicy` CRs.
>
> **Official Limitador metrics** (RHOAI 3.4):
> - `authorized_hits` — token count for authorized requests
> - `authorized_calls` — request count for authorized requests
> - `limited_calls` — request count for rate-limited (429) requests

---

## Auth & Access Control

### Auth decisions per subscription (allow vs deny)
```promql
rate(auth_server_authconfig_total[5m])
```

### Auth denial rate by auth config
```promql
rate(auth_server_authconfig_total{authconfig_result!="OK"}[5m])
```

### Total auth requests by subscription over time
```promql
increase(auth_server_authconfig_total[1h])
```

---

## Rate Limiting & Token Metering

### Authorized tokens (token-count metric per subscription)
```promql
authorized_hits{namespace="models-as-a-service"}
```

### Authorized calls (request count that passed rate limiting)
```promql
authorized_calls{namespace="models-as-a-service"}
```

### Limited calls (requests rejected with HTTP 429)
```promql
limited_calls{namespace="models-as-a-service"}
```

### Token consumption rate per subscription
```promql
rate(authorized_hits{namespace="models-as-a-service"}[5m])
```

### Rate-limited request rate (429s per second)
```promql
rate(limited_calls{namespace="models-as-a-service"}[5m])
```

### Ratio of rate-limited to total requests
```promql
limited_calls{namespace="models-as-a-service"}
/ (authorized_calls{namespace="models-as-a-service"} + limited_calls{namespace="models-as-a-service"})
```

---

## Model Inference Performance

### Inference request rate (per model)
```promql
rate(vllm:generation_tokens_total[5m])
```

### Time to First Token (P50, P95, P99)
```promql
histogram_quantile(0.50, rate(vllm:time_to_first_token_seconds_bucket[5m]))
histogram_quantile(0.95, rate(vllm:time_to_first_token_seconds_bucket[5m]))
histogram_quantile(0.99, rate(vllm:time_to_first_token_seconds_bucket[5m]))
```

### End-to-end request duration (P95)
```promql
histogram_quantile(0.95, rate(vllm:e2e_request_latency_seconds_bucket[5m]))
```

### Tokens generated per second (throughput)
```promql
rate(vllm:generation_tokens_total[1m])
```

### GPU cache utilization
```promql
vllm:gpu_cache_usage_perc
```

### Active inference requests (queue depth)
```promql
vllm:num_requests_running
```

### Queued requests waiting for GPU
```promql
vllm:num_requests_waiting
```

---

## Error Rates

### Backend error rate (5xx)
```promql
rate(envoy_cluster_upstream_rq_xx{envoy_response_code_class="5"}[5m])
```

### Client error rate (4xx, excluding 429)
```promql
rate(envoy_cluster_upstream_rq_xx{envoy_response_code_class="4", envoy_response_code!="429"}[5m])
```

### Total error ratio
```promql
sum(rate(envoy_cluster_upstream_rq_xx{envoy_response_code_class=~"4|5"}[5m]))
/ sum(rate(envoy_cluster_upstream_rq_xx[5m]))
```

---

## Chargeback & Capacity Planning

### Total tokens consumed per subscription (last 24h)
```promql
increase(authorized_hits{namespace="models-as-a-service"}[24h])
```

### Total requests per subscription (last 24h)
```promql
increase(authorized_calls{namespace="models-as-a-service"}[24h])
```

### Peak concurrent requests per subscription (over 1h)
```promql
max_over_time(vllm:num_requests_running[1h])
```

---

## How to Use in OpenShift Console

1. Navigate to **Observe → Metrics** in the OpenShift Console
2. Paste any query above into the query editor
3. Select the time range (last 1h, 6h, 24h)
4. For per-subscription views, filter by labels: `limitador_namespace`, `authconfig_name`

## Dashboard Integration

RHOAI 3.4 includes a built-in **Perses dashboard** (Technology Preview) embedded in the OpenShift AI console that visualizes token usage, rate limit status, and subscription activity.

For custom dashboards, these queries can be used in:
- **OpenShift Console → Observe → Metrics** (ad-hoc queries)
- **PrometheusRule** alerts (see `manifests/platform/observability/prometheus-rules.yaml`)

Navigate to **OpenShift AI Console → Models-as-a-Service → Usage Dashboard** for the built-in Perses dashboard.
