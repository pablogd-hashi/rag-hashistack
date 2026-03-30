# Vault Secrets Operator Integration

This guide covers the integration between HashiCorp Vault and OpenShift using the Vault Secrets Operator (VSO) for dynamic secret management in the RAG platform.

## Overview

The Vault Secrets Operator (VSO) enables OpenShift workloads to consume secrets from Vault without embedding Vault tokens or credentials in application code. VSO automatically syncs secrets from Vault to Kubernetes Secret objects.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     OpenShift Cluster                        │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Vault Secrets Operator (VSO)                        │  │
│  │  - Watches VaultStaticSecret CRDs                    │  │
│  │  - Authenticates to Vault via Kubernetes auth        │  │
│  │  - Syncs secrets to Kubernetes Secrets               │  │
│  └──────────────────────────────────────────────────────┘  │
│                          │                                   │
│                          │ Kubernetes Auth                   │
│                          ▼                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  HashiCorp Vault                                     │  │
│  │  - KV v2 Secrets Engine: kv/rag/*                   │  │
│  │  - Kubernetes Auth Method                            │  │
│  │  - Policies: rag-reader                              │  │
│  └──────────────────────────────────────────────────────┘  │
│                          │                                   │
│                          │ Read Secrets                      │
│                          ▼                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Application Pods                                    │  │
│  │  - query-service: reads qdrant-credentials           │  │
│  │  - ingest: reads qdrant-credentials                  │  │
│  │  - Secrets mounted as env vars or files              │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## How It Works

### 1. Kubernetes Authentication

VSO authenticates to Vault using the Kubernetes auth method:

1. VSO presents its ServiceAccount JWT token to Vault
2. Vault validates the token with the Kubernetes API server
3. Vault returns a Vault token with policies attached
4. VSO uses this token to read secrets

**Vault Configuration:**
```bash
# Enable Kubernetes auth
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

# Create role for VSO
vault write auth/kubernetes/role/rag-role \
  bound_service_account_names=rag-query,rag-ingest \
  bound_service_account_namespaces=rag-platform \
  policies=rag-reader \
  ttl=1h
```

### 2. Secret Synchronization

VSO watches for `VaultStaticSecret` custom resources and syncs secrets from Vault to Kubernetes:

**VaultStaticSecret Example:**
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: qdrant-config
  namespace: rag-platform
spec:
  vaultAuthRef: rag-auth
  mount: kv
  type: kv-v2
  path: rag/qdrant
  refreshAfter: 30s
  destination:
    create: true
    name: qdrant-credentials
```

**Resulting Kubernetes Secret:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: qdrant-credentials
  namespace: rag-platform
type: Opaque
data:
  api_key: ZGV2LWtleS0xMjM0NQ==  # base64 encoded
  url: aHR0cDovL3FkcmFudDo2MzMz
```

### 3. Application Consumption

Applications consume secrets as environment variables or mounted files:

**Deployment Example:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: query-service
spec:
  template:
    spec:
      containers:
      - name: query-service
        image: query-service:latest
        env:
        - name: QDRANT_API_KEY
          valueFrom:
            secretKeyRef:
              name: qdrant-credentials
              key: api_key
        - name: QDRANT_URL
          valueFrom:
            secretKeyRef:
              name: qdrant-credentials
              key: url
```

## VSO Components

### VaultConnection

Defines how to connect to Vault:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault-connection
  namespace: rag-platform
spec:
  address: http://vault.vault.svc.cluster.local:8200
  skipTLSVerify: true  # Only for dev/CRC
```

### VaultAuth

Defines authentication method:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: rag-auth
  namespace: rag-platform
spec:
  vaultConnectionRef: vault-connection
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: rag-role
    serviceAccount: rag-query
```

### VaultStaticSecret

Defines which secret to sync:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: qdrant-config
  namespace: rag-platform
spec:
  vaultAuthRef: rag-auth
  mount: kv
  type: kv-v2
  path: rag/qdrant
  refreshAfter: 30s
  destination:
    create: true
    name: qdrant-credentials
```

## Secret Rotation

VSO automatically refreshes secrets based on `refreshAfter` interval:

1. VSO reads secret from Vault every 30s (configurable)
2. If secret changed, VSO updates Kubernetes Secret
3. Pods can be configured to restart on secret change

**Automatic Pod Restart:**
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: qdrant-config
spec:
  # ... other fields ...
  rolloutRestartTargets:
  - kind: Deployment
    name: query-service
```

## Security Considerations

### Least Privilege

Each service has its own ServiceAccount and Vault role:

```bash
# query-service role
vault write auth/kubernetes/role/query-role \
  bound_service_account_names=rag-query \
  bound_service_account_namespaces=rag-platform \
  policies=rag-query-reader \
  ttl=1h

# ingest role
vault write auth/kubernetes/role/ingest-role \
  bound_service_account_names=rag-ingest \
  bound_service_account_namespaces=rag-platform \
  policies=rag-ingest-reader \
  ttl=1h
```

### Vault Policies

Policies define what secrets each service can access:

**rag-query-reader.hcl:**
```hcl
# Read Qdrant credentials
path "kv/data/rag/qdrant" {
  capabilities = ["read"]
}

# Read Ollama config
path "kv/data/rag/ollama" {
  capabilities = ["read"]
}
```

**rag-ingest-reader.hcl:**
```hcl
# Read Qdrant credentials
path "kv/data/rag/qdrant" {
  capabilities = ["read"]
}

# Read Ollama config
path "kv/data/rag/ollama" {
  capabilities = ["read"]
}
```

### Network Policies

Restrict network access between services:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vso-to-vault
  namespace: rag-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: vault-secrets-operator
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: vault
    ports:
    - protocol: TCP
      port: 8200
```

## Demo Setup (CRC)

### Prerequisites

- CRC running with 20GB RAM, 6 CPUs
- `oc` CLI configured
- `helm` CLI installed
- `vault` CLI installed

### Step 1: Deploy Vault in Dev Mode

```bash
# Create vault namespace
oc new-project vault

# Deploy Vault in dev mode (NOT for production!)
oc apply -f k8s/vault/vault-dev.yaml

# Wait for Vault to be ready
oc wait --for=condition=ready pod -l app=vault -n vault --timeout=120s

# Port-forward to access Vault
oc port-forward -n vault svc/vault 8200:8200 &

# Set Vault address
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root  # Dev mode root token
```

### Step 2: Configure Vault

```bash
# Enable KV v2
vault secrets enable -path=kv kv-v2

# Create secrets
vault kv put kv/rag/qdrant \
  api_key="" \
  url="http://qdrant.rag-platform.svc.cluster.local:6333"

vault kv put kv/rag/ollama \
  url="http://ollama.rag-platform.svc.cluster.local:11434"

# Enable Kubernetes auth
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Create policy
vault policy write rag-reader - <<EOF
path "kv/data/rag/*" {
  capabilities = ["read"]
}
EOF

# Create role
vault write auth/kubernetes/role/rag-role \
  bound_service_account_names=rag-query,rag-ingest,default \
  bound_service_account_namespaces=rag-platform \
  policies=rag-reader \
  ttl=1h
```

### Step 3: Install VSO

```bash
# Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Install VSO
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator-system \
  --create-namespace \
  --set defaultVaultConnection.enabled=true \
  --set defaultVaultConnection.address=http://vault.vault.svc.cluster.local:8200

# Wait for VSO to be ready
oc wait --for=condition=ready pod \
  -l app.kubernetes.io/name=vault-secrets-operator \
  -n vault-secrets-operator-system \
  --timeout=120s
```

### Step 4: Deploy RAG Platform

```bash
# Create namespace
oc new-project rag-platform

# Apply VSO resources
oc apply -f k8s/vault/vault-connection.yaml
oc apply -f k8s/vault/vault-auth.yaml
oc apply -f k8s/vault/qdrant-secret.yaml
oc apply -f k8s/vault/ollama-secret.yaml

# Wait for secrets to sync
sleep 10

# Verify secrets created
oc get secrets -n rag-platform

# Deploy applications
oc apply -f k8s/base/
```

## Troubleshooting

### VSO Not Syncing Secrets

**Check VSO logs:**
```bash
oc logs -n vault-secrets-operator-system \
  -l app.kubernetes.io/name=vault-secrets-operator \
  --tail=50
```

**Common issues:**
- Vault connection failed: Check `VaultConnection` address
- Authentication failed: Verify Kubernetes auth configuration
- Permission denied: Check Vault policy and role binding

### Secret Not Appearing in Pod

**Check VaultStaticSecret status:**
```bash
oc describe vaultstaticsecret qdrant-config -n rag-platform
```

**Check if secret exists:**
```bash
oc get secret qdrant-credentials -n rag-platform
```

**Check pod events:**
```bash
oc describe pod <pod-name> -n rag-platform
```

### Vault Authentication Issues

**Test Kubernetes auth manually:**
```bash
# Get ServiceAccount token
SA_TOKEN=$(oc sa get-token rag-query -n rag-platform)

# Test authentication
vault write auth/kubernetes/login \
  role=rag-role \
  jwt=$SA_TOKEN
```

## Best Practices

1. **Use TLS in Production:** Always enable TLS for Vault in production
2. **Rotate Secrets Regularly:** Set appropriate `refreshAfter` intervals
3. **Least Privilege:** Create separate roles and policies per service
4. **Monitor Secret Access:** Enable Vault audit logging
5. **Backup Vault Data:** Regularly backup Vault storage backend
6. **Use External Vault:** Don't run Vault in the same cluster for production

## References

- Vault Secrets Operator: https://developer.hashicorp.com/vault/docs/platform/k8s/vso
- Kubernetes Auth Method: https://developer.hashicorp.com/vault/docs/auth/kubernetes
- KV Secrets Engine: https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2
- OpenShift Security: https://docs.openshift.com/container-platform/latest/authentication/index.html
