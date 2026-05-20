# Per-Subscription PromQL Queries

Pre-built queries for monitoring AI Bridge subscription usage in OpenShift Console → Observe → Metrics.

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

### Current rate limit counter value per subscription
```promql
limitador_counter_value{namespace="models-as-a-service"}
```

### Rate limit utilization percentage per subscription
```promql
limitador_counter_value / limitador_counter_max_value
```

### Requests being rate limited (429s issued)
```promql
rate(limitador_requests_total{limited="true"}[5m])
```

### Token consumption rate per subscription
```promql
rate(limitador_counter_value[5m])
```

### Time until rate limit reset
```promql
limitador_counter_ttl_seconds
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
increase(limitador_counter_value{namespace="models-as-a-service"}[24h])
```

### Subscription quota remaining
```promql
limitador_counter_max_value - limitador_counter_value
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

These queries power the `ai-gateway-dashboard` ConfigMap deployed via:
```
manifests/platform/observability/dashboard-configmap.yaml
```

Navigate to **Observe → Dashboards → AI Gateway - Multi-Tenant Inference** for the pre-built dashboard.
