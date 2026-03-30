# OpenShift Deployment Architecture

This document describes the architecture of the RAG platform deployed on OpenShift with Vault Secrets Operator (VSO) for secret management.

## Overview

The RAG platform runs on OpenShift Local (CRC) for development and can be deployed to production OpenShift clusters with minimal changes. The architecture emphasizes security, scalability, and operational simplicity.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          OpenShift Cluster (CRC)                             │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                        Namespace: vault                                 │ │
│  │  ┌──────────────────────────────────────────────────────────────────┐  │ │
│  │  │  Vault (Dev Mode)                                                │  │ │
│  │  │  - KV v2: kv/rag/*                                              │  │ │
│  │  │  - Kubernetes Auth                                               │  │ │
│  │  │  - Policies: rag-reader                                          │  │ │
│  │  │  - Service: vault.vault.svc.cluster.local:8200                  │  │ │
│  │  └──────────────────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    │ Kubernetes Auth                         │
│                                    ▼                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │              Namespace: vault-secrets-operator-system                   │ │
│  │  ┌──────────────────────────────────────────────────────────────────┐  │ │
│  │  │  Vault Secrets Operator (VSO)                                    │  │ │
│  │  │  - Watches VaultStaticSecret CRDs                                │  │ │
│  │  │  - Authenticates to Vault                                        │  │ │
│  │  │  - Syncs secrets to Kubernetes Secrets                           │  │ │
│  │  └──────────────────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    │ Secret Sync                             │
│                                    ▼                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                      Namespace: rag-platform                            │ │
│  │                                                                          │ │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐           │ │
│  │  │ Qdrant         │  │ Ollama         │  │ Query Service  │           │ │
│  │  │ StatefulSet    │  │ Deployment     │  │ Deployment     │           │ │
│  │  │ - PVC: 10Gi    │  │ - PVC: 20Gi    │  │ - Replicas: 1  │           │ │
│  │  │ - Port: 6333   │  │ - Port: 11434  │  │ - Port: 8000   │           │ │
│  │  └────────────────┘  └────────────────┘  └────────────────┘           │ │
│  │         │                    │                    │                     │ │
│  │         │                    │                    │                     │ │
│  │  ┌──────▼────────────────────▼────────────────────▼──────────────┐    │ │
│  │  │              Kubernetes Secrets (from VSO)                     │    │ │
│  │  │  - qdrant-credentials (url, api_key)                          │    │ │
│  │  │  - ollama-credentials (url)                                   │    │ │
│  │  └────────────────────────────────────────────────────────────────┘    │ │
│  │                                                                          │ │
│  │  ┌────────────────┐  ┌────────────────┐                                │ │
│  │  │ UI             │  │ Ingest Job     │                                │ │
│  │  │ Deployment     │  │ Batch Job      │                                │ │
│  │  │ - Port: 8501   │  │ - Run once     │                                │ │
│  │  │ - Route: HTTPS │  │ - ConfigMap    │                                │ │
│  │  └────────────────┘  └────────────────┘                                │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    │ OpenShift Route                         │
│                                    ▼                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  OpenShift Router (HAProxy)                                            │ │
│  │  - ui-rag-platform.apps-crc.testing                                    │ │
│  │  - TLS termination                                                     │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ HTTPS
                                    ▼
                              User Browser
```

## Components

### 1. Vault (Dev Mode)

**Purpose:** Centralized secret management

**Configuration:**
- **Namespace:** `vault`
- **Mode:** Dev (in-memory storage, root token: `root`)
- **Secrets Engine:** KV v2 at `kv/`
- **Auth Method:** Kubernetes auth
- **Service:** `vault.vault.svc.cluster.local:8200`

**Secrets Stored:**
```
kv/rag/qdrant:
  - api_key: "" (empty for dev)
  - url: "http://qdrant.rag-platform.svc.cluster.local:6333"

kv/rag/ollama:
  - url: "http://ollama.rag-platform.svc.cluster.local:11434"
```

**Production Considerations:**
- Use external Vault cluster
- Enable TLS
- Use persistent storage (Consul, etcd, or cloud storage)
- Implement HA with multiple replicas
- Enable audit logging
- Use AppRole or JWT auth instead of root token

### 2. Vault Secrets Operator (VSO)

**Purpose:** Sync secrets from Vault to Kubernetes

**Configuration:**
- **Namespace:** `vault-secrets-operator-system`
- **Helm Chart:** `hashicorp/vault-secrets-operator`
- **Version:** 0.8.0+

**Custom Resources:**
- `VaultConnection`: Defines Vault server address
- `VaultAuth`: Configures Kubernetes auth
- `VaultStaticSecret`: Defines which secrets to sync

**How It Works:**
1. VSO authenticates to Vault using ServiceAccount JWT
2. Vault validates JWT with Kubernetes API
3. VSO reads secrets from specified paths
4. VSO creates/updates Kubernetes Secrets
5. VSO refreshes secrets every 30s (configurable)
6. VSO can trigger pod restarts on secret change

### 3. Qdrant (Vector Database)

**Purpose:** Store document embeddings

**Configuration:**
- **Type:** StatefulSet (for persistent storage)
- **Replicas:** 1
- **Storage:** 10Gi PVC
- **Ports:** 6333 (HTTP), 6334 (gRPC)
- **Image:** `qdrant/qdrant:v1.13.2`

**Resources:**
- Requests: 512Mi RAM, 250m CPU
- Limits: 2Gi RAM, 1000m CPU

**Security:**
- No API key in dev mode
- Production: Enable API key from Vault
- Network policies restrict access

### 4. Ollama (LLM Server)

**Purpose:** Serve embedding and chat models

**Configuration:**
- **Type:** Deployment
- **Replicas:** 1
- **Storage:** 20Gi PVC for models
- **Port:** 11434
- **Image:** `ollama/ollama:latest`

**Models:**
- `nomic-embed-text`: 768-dim embeddings (~274MB)
- `mistral`: Chat model (~4.4GB)

**Init Container:**
- Pulls models before main container starts
- Ensures models are available immediately

**Resources:**
- Requests: 4Gi RAM, 1000m CPU
- Limits: 8Gi RAM, 4000m CPU

**Production Considerations:**
- Use GPU nodes for better performance
- Increase replicas for HA
- Use model caching/preloading

### 5. Query Service (FastAPI)

**Purpose:** RAG query endpoint

**Configuration:**
- **Type:** Deployment
- **Replicas:** 1 (can scale with HPA)
- **Port:** 8000
- **Image:** `query-service:latest`

**Environment Variables (from Vault):**
- `QDRANT_URL`: Qdrant service URL
- `QDRANT_API_KEY`: Qdrant API key (optional)
- `OLLAMA_URL`: Ollama service URL
- `EMBED_MODEL`: nomic-embed-text
- `LLM_MODEL`: mistral
- `COLLECTION`: platform-docs
- `TOP_K`: 5

**Endpoints:**
- `GET /health`: Health check
- `POST /ask`: Query endpoint

**Resources:**
- Requests: 512Mi RAM, 250m CPU
- Limits: 1Gi RAM, 1000m CPU

### 6. UI (Streamlit)

**Purpose:** Web interface for queries

**Configuration:**
- **Type:** Deployment
- **Replicas:** 1
- **Port:** 8501
- **Image:** `ui:latest`
- **Route:** HTTPS via OpenShift Router

**Environment Variables:**
- `API_URL`: Query service URL

**Resources:**
- Requests: 256Mi RAM, 100m CPU
- Limits: 512Mi RAM, 500m CPU

**Access:**
- External: `https://ui-rag-platform.apps-crc.testing`
- Internal: `http://ui.rag-platform.svc.cluster.local:8501`

### 7. Ingest Job

**Purpose:** Batch ingestion of documents

**Configuration:**
- **Type:** Job (one-time execution)
- **Restart Policy:** OnFailure
- **Backoff Limit:** 3
- **Image:** `ingest:latest`

**Environment Variables (from Vault):**
- `QDRANT_URL`: Qdrant service URL
- `QDRANT_API_KEY`: Qdrant API key (optional)
- `OLLAMA_URL`: Ollama service URL
- `EMBED_MODEL`: nomic-embed-text
- `COLLECTION`: platform-docs
- `DOCS_PATH`: /docs

**Volume:**
- ConfigMap with documentation files
- Production: Use git-sync sidecar or S3

**Resources:**
- Requests: 1Gi RAM, 500m CPU
- Limits: 2Gi RAM, 1000m CPU

## Networking

### Service Communication

All services communicate via Kubernetes Services (ClusterIP):

```
ui → query-service.rag-platform.svc.cluster.local:8000
query-service → qdrant.rag-platform.svc.cluster.local:6333
query-service → ollama.rag-platform.svc.cluster.local:11434
ingest → qdrant.rag-platform.svc.cluster.local:6333
ingest → ollama.rag-platform.svc.cluster.local:11434
vso → vault.vault.svc.cluster.local:8200
```

### External Access

- **UI:** OpenShift Route with TLS termination
- **Vault:** Port-forward for dev (8200)
- **Query API:** Internal only (accessed via UI)

### Network Policies (Future)

```yaml
# Allow VSO to Vault
vso → vault:8200

# Allow query-service to Qdrant and Ollama
query-service → qdrant:6333
query-service → ollama:11434

# Allow ingest to Qdrant and Ollama
ingest → qdrant:6333
ingest → ollama:11434

# Allow UI to query-service
ui → query-service:8000

# Deny all other traffic
```

## Storage

### Persistent Volumes

1. **Qdrant Storage (10Gi)**
   - Type: StatefulSet VolumeClaimTemplate
   - Access Mode: ReadWriteOnce
   - Purpose: Vector database storage

2. **Ollama Models (20Gi)**
   - Type: PersistentVolumeClaim
   - Access Mode: ReadWriteOnce
   - Purpose: LLM model storage

### Storage Classes

CRC uses the default storage class (local storage).

Production considerations:
- Use network storage (NFS, Ceph, cloud storage)
- Enable snapshots for backups
- Set appropriate IOPS for Qdrant

## Security

### Pod Security

All pods run with:
- `runAsNonRoot: true`
- `runAsUser: 1000`
- `fsGroup: 1000`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: [ALL]`

### Secret Management

- Secrets stored in Vault (not in Git)
- VSO syncs secrets to Kubernetes Secrets
- Pods consume secrets as environment variables
- Secrets refreshed every 30s
- Automatic pod restart on secret change

### RBAC

Each service has minimal permissions:
- ServiceAccount per service
- Vault role per ServiceAccount
- Vault policy per role

### Network Security

- Services use ClusterIP (internal only)
- UI exposed via Route with TLS
- Network policies restrict traffic (future)

## Scalability

### Horizontal Scaling

**Query Service:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: query-service
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: query-service
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

**UI:**
- Can scale to multiple replicas
- No state, fully stateless

### Vertical Scaling

**Qdrant:**
- Increase PVC size
- Increase memory/CPU limits

**Ollama:**
- Use GPU nodes
- Increase memory for larger models

## Monitoring

### Health Checks

All services have:
- Readiness probes (service ready to accept traffic)
- Liveness probes (service is alive)

### Metrics (Future)

- Prometheus metrics from all services
- Grafana dashboards
- Alerts for:
  - High retrieval latency
  - Low cosine similarity scores
  - Pod restarts
  - Secret sync failures

## Deployment Workflow

1. **Setup CRC:** `task setup-crc`
2. **Deploy Vault:** `task deploy-vault`
3. **Configure Vault:** `task configure-vault`
4. **Install VSO:** `task deploy-vso`
5. **Deploy VSO Resources:** `task deploy-vso-resources`
6. **Deploy RAG Platform:** `task deploy-rag`
7. **Run Ingest:** `task run-ingest`
8. **Expose UI:** `task expose-ui`

Or run everything: `task demo`

## Production Readiness

### Required Changes

1. **Vault:**
   - Use external Vault cluster
   - Enable TLS
   - Use persistent storage
   - Implement HA
   - Enable audit logging

2. **Storage:**
   - Use network storage
   - Enable backups
   - Set appropriate IOPS

3. **Security:**
   - Enable Network Policies
   - Use Pod Security Standards
   - Implement RBAC
   - Enable audit logging

4. **Monitoring:**
   - Deploy Prometheus/Grafana
   - Set up alerts
   - Enable distributed tracing

5. **Scaling:**
   - Enable HPA for query-service
   - Use GPU nodes for Ollama
   - Implement caching

6. **CI/CD:**
   - Automate image builds
   - Implement GitOps (ArgoCD)
   - Automate testing

## References

- OpenShift Documentation: https://docs.openshift.com/
- Vault Secrets Operator: https://developer.hashicorp.com/vault/docs/platform/k8s/vso
- Qdrant Documentation: https://qdrant.tech/documentation/
- Ollama Documentation: https://ollama.ai/
