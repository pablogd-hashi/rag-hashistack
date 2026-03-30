#!/bin/bash
set -euo pipefail

# Configure Vault for OpenShift integration
# This script sets up KV secrets, Kubernetes auth, and policies

echo "Configuring Vault..."

# Wait for Vault to be ready
echo "Waiting for Vault to be ready..."
for i in {1..30}; do
  if vault status >/dev/null 2>&1; then
    echo "✓ Vault is ready"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "❌ Vault did not become ready in time"
    exit 1
  fi
  sleep 2
done

# Enable KV v2 secrets engine
echo "Enabling KV v2 secrets engine..."
vault secrets enable -path=kv kv-v2 2>/dev/null || echo "KV already enabled"

# Create secrets for RAG platform
echo "Creating secrets..."
vault kv put kv/rag/qdrant \
  api_key="" \
  url="http://qdrant.rag-platform.svc.cluster.local:6333"

vault kv put kv/rag/ollama \
  url="http://ollama.rag-platform.svc.cluster.local:11434"

echo "✓ Secrets created"

# Enable Kubernetes auth method
echo "Enabling Kubernetes auth..."
vault auth enable kubernetes 2>/dev/null || echo "Kubernetes auth already enabled"

# Configure Kubernetes auth
echo "Configuring Kubernetes auth..."
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

echo "✓ Kubernetes auth configured"

# Create policy for RAG services
echo "Creating Vault policy..."
vault policy write rag-reader - <<EOF
# Allow reading all RAG secrets
path "kv/data/rag/*" {
  capabilities = ["read"]
}

# Allow listing RAG secrets
path "kv/metadata/rag/*" {
  capabilities = ["list"]
}
EOF

echo "✓ Policy created"

# Create Kubernetes auth role
echo "Creating Kubernetes auth role..."
vault write auth/kubernetes/role/rag-role \
  bound_service_account_names=default,rag-query,rag-ingest \
  bound_service_account_namespaces=rag-platform \
  policies=rag-reader \
  ttl=1h

echo "✓ Role created"

# Verify configuration
echo ""
echo "Verifying configuration..."
echo "Secrets:"
vault kv list kv/rag/

echo ""
echo "Policy:"
vault policy read rag-reader

echo ""
echo "✓ Vault configuration complete"
