# Secrets Management

This demo uses **HashiCorp Vault** + **External Secrets Operator (ESO)** to keep
all sensitive values out of Git while maintaining a fully GitOps-driven workflow.

## Architecture

```
┌─────────────┐       ┌──────────────────┐       ┌──────────────┐
│  Git Repo   │──────▶│  ArgoCD syncs    │──────▶│  Kubernetes  │
│ (no secrets)│       │  ExternalSecret  │       │  cluster     │
└─────────────┘       │  manifests       │       └──────┬───────┘
                      └──────────────────┘              │
                                                        ▼
                      ┌──────────────────┐       ┌──────────────┐
                      │  Vault (in-mem)  │◀──────│  ESO syncs   │
                      │  dev server      │       │  secrets     │
                      └──────────────────┘       └──────────────┘
```

## Pre-requisites (one-time manual setup)

Before ArgoCD can sync successfully, create these secrets manually on the cluster.
They are **never** stored in Git.

### 1. Vault Token Secret (gateway cluster)

```bash
oc create secret generic vault-token \
  -n vault-dev \
  --from-literal=token=<your-vault-root-token>
```

### 2. Vault Seed Credentials (gateway cluster)

Used by the `vault-init` Job to populate Vault with application secrets:

```bash
oc create secret generic vault-seed-credentials \
  -n vault-dev \
  --from-literal=vault-token=<your-vault-root-token> \
  --from-literal=team-a-key=<api-key-for-team-a> \
  --from-literal=team-b-key=<api-key-for-team-b> \
  --from-literal=postgres-password=<db-password> \
  --from-literal=database-url='postgresql://maas:<db-password>@postgresql.maas-db.svc:5432/maas?sslmode=disable'
```

### 3. Keycloak Client Secret (if not managed by operator)

The Keycloak client `ai-bridge-gateway` credentials are managed inside Keycloak
itself and do not need a separate Kubernetes secret.

## How Secrets Flow

1. **Operator** creates `vault-token` and `vault-seed-credentials` manually (or via CI with secrets stored in the pipeline).
2. **ArgoCD** syncs the Vault deployment; on PostSync, the `vault-init` Job reads env vars from `vault-seed-credentials` and seeds Vault paths.
3. **ESO** watches `ExternalSecret` resources and syncs Kubernetes Secrets from Vault at the configured refresh interval.
4. **Pods** mount the generated Kubernetes Secrets as normal (env vars or volume mounts).

## Vault Paths

| Vault Path | Properties | Used By |
|------------|-----------|---------|
| `secret/ai-bridge/api-keys` | `team-a-key`, `team-b-key` | ExternalSecret `ai-bridge-api-keys` |
| `secret/ai-bridge/db-credentials` | `postgres-password`, `postgres-url` | ExternalSecret `maas-db-config` |
| `secret/gemini-credentials` | `api-key` | ExternalSecret `gemini-credentials` |
| `secret/vllm-cluster2-credentials` | `api-key` | ExternalSecret `vllm-cluster2-credentials` |

## ExternalModel Provider Credentials

Provider credential Secrets (referenced by `ExternalModel.spec.credentialRef`) have a
**critical undocumented requirement**: the Secret MUST carry the label
`inference.networking.k8s.io/bbr-managed: "true"`. Without this label, the
payload-processing `apikey-injection` plugin will not load the credentials into its
in-memory store, and inference calls will fail with "credentials not found".

The ExternalSecret templates in `manifests/external-models/external-secrets.yaml`
use `target.template.metadata.labels` to ensure the label is applied automatically
when ESO syncs from Vault.

The Secret data key must be exactly `api-key` (not `apiKey`, not `api_key`).

## For Production

Replace the dev-mode Vault with a production Vault instance:
- Use Kubernetes auth method instead of token auth
- Enable audit logging
- Use auto-unseal with a KMS provider
- Consider Sealed Secrets or SOPS as alternatives for simpler setups
