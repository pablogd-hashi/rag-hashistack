# rag-hashicorp-platform

A RAG (Retrieval-Augmented Generation) platform that indexes internal platform
documents — Markdown runbooks, HCL policies, Terraform files — into a Qdrant
vector database and answers natural-language questions about them.

Production credential delivery uses **HashiCorp Vault** with AppRole auth.
Service-to-service communication is secured with **Consul Connect** mTLS using
SPIFFE-issued X.509 certificates.

> Companion repository for the blog post:
> *Operationalising a RAG Platform with Vault, SPIFFE, and Consul*.

---

## Architecture

```
┌──────────┐    ┌──────────────┐    ┌────────┐
│ Streamlit │───▶│ Query Service │───▶│ Qdrant │
│    UI     │    │  (FastAPI)   │    └────────┘
└──────────┘    │              │───▶┌────────┐
                │              │    │ Ollama │
                └──────────────┘    └────────┘
                       ▲
                ┌──────┴──────┐
                │   Ingest    │  (batch — reads ./docs)
                └─────────────┘
```

- **Embedding model:** `nomic-embed-text` (768 dimensions)
- **Chat model:** `mistral`
- **Vector store:** Qdrant with cosine similarity

---

## Deployment Options

This platform supports two deployment modes:

1. **Docker Compose** (Local Development) - Quick start for testing
2. **OpenShift** (Production-Ready) - Full platform with Vault VSO integration

### Docker Compose Prerequisites

| Tool             | Version |
|------------------|---------|
| Docker Desktop   | 4.x+    |
| Docker Compose   | v2      |
| Task             | any     |

> On Apple Silicon, both Ollama models run natively. The demo flow
> completes in under 3 seconds once models are loaded.

### OpenShift Prerequisites

| Tool                  | Version | Purpose                          |
|-----------------------|---------|----------------------------------|
| OpenShift Local (CRC) | 2.x+    | Local OpenShift cluster          |
| oc CLI                | 4.x+    | OpenShift command-line interface |
| helm                  | 3.x+    | Vault Secrets Operator install   |
| vault CLI             | 1.15+   | Vault configuration              |
| Task                  | any     | Automation                       |

**System Requirements for CRC:**
- Memory: 20 GB RAM
- CPU: 6 cores
- Disk: 80 GB free space

See [CRC Prerequisites](docs/configuration/crc-prerequisites.md) for detailed setup instructions.

---

## Quick Start

### Option 1: Docker Compose (Local Development)

```bash
# Clone and setup
git clone https://github.com/<you>/rag-hashicorp-platform.git
cd rag-hashicorp-platform

# Run full demo (setup + ingest + start services)
task demo:docker
# or simply: task demo
```

**Access services:**
- UI: http://localhost:8501
- Query API: http://localhost:8000
- Qdrant: http://localhost:6333

**Try asking:**
> *Which runbook covers a leader election failure?*

**Useful commands:**
```bash
task status              # Check services
task logs -- ui          # View logs
task walkthrough         # Interactive demo
task clean               # Stop everything
```

### Option 2: OpenShift (Production with Vault + Consul)

```bash
# Clone and setup
git clone https://github.com/<you>/rag-hashicorp-platform.git
cd rag-hashicorp-platform

# Setup infrastructure (CRC + Vault + Consul + VSO)
task setup:ocp

# Run full demo
task demo:ocp
```

**Access services:**
- UI: https://ui-rag-platform.apps-crc.testing
- Vault: http://localhost:8200 (token: root)
- Consul UI: `oc port-forward -n consul svc/consul-ui 8500:80`

**Useful commands:**
```bash
task status:ocp              # Check all services
task logs:ocp -- query-service
task clean:ocp               # Remove everything
task stop:ocp                # Stop CRC
```

**Key Features:**
- ✅ **Consul Connect Service Mesh** - mTLS between all services
- ✅ **SPIFFE Identities** - Cryptographic service identities
- ✅ **Vault Secrets Operator** - Dynamic secret management
- ✅ **Automatic Secret Rotation** - 30s refresh with pod restart
- ✅ **Service Intentions** - Fine-grained authorization policies
- ✅ **Production-Ready Architecture** - StatefulSets, PVCs, health checks
- ✅ **OpenShift Routes** - HTTPS ingress with TLS termination

See [OpenShift Deployment Guide](docs/architecture/openshift-deployment.md) for details.

---

## Manual Step-by-Step

If you prefer to run each stage yourself:

```bash
# 1. Start Ollama and pull models
task setup

# 2. Ingest the sample documents
task ingest

# 3. Start the query service and UI
task up
```

### Service URLs

| Service      | URL                        |
|--------------|----------------------------|
| Qdrant       | http://localhost:6333       |
| Query API    | http://localhost:8000       |
| Streamlit UI | http://localhost:8501       |

### Stop everything

```bash
task down       # stop containers
task clean      # stop containers AND delete volumes
```

---

## Adding Your Own Documents

1. Place `.md`, `.hcl`, or `.tf` files anywhere under `./docs/`.
2. Re-run the ingest pipeline:
   ```bash
   task ingest
   ```
3. The chunker automatically dispatches to the correct strategy:
   - **Markdown** → heading-aware splitting (H1/H2/H3 boundaries).
   - **HCL / Terraform** → top-level block-aware splitting (`resource`,
     `data`, `module`, etc.) so semantic blocks are never bisected.

---

## Understanding Retrieval Scores

The Streamlit UI displays the **top cosine similarity score** from Qdrant
for each query.

| Score   | Meaning                                                  |
|---------|----------------------------------------------------------|
| ≥ 0.5   | Good match — the answer is grounded in indexed content.  |
| < 0.5   | Weak match — the index may be stale, or the question is out of scope. Re-ingest or rephrase the query. |

This score is the primary signal for retrieval quality degradation in
production monitoring.

---

## OpenShift Deployment with Vault VSO

The platform includes a production-ready OpenShift deployment using Vault Secrets Operator (VSO) for dynamic secret management.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    OpenShift Cluster (CRC)                   │
│                                                              │
│  ┌──────────────┐    ┌──────────────────┐                  │
│  │   Vault      │───▶│  VSO (Operator)  │                  │
│  │  (Dev Mode)  │    │  Syncs Secrets   │                  │
│  └──────────────┘    └──────────────────┘                  │
│         │                      │                             │
│         │                      ▼                             │
│         │         ┌────────────────────────┐                │
│         │         │  Kubernetes Secrets    │                │
│         │         │  - qdrant-credentials  │                │
│         │         │  - ollama-credentials  │                │
│         │         └────────────────────────┘                │
│         │                      │                             │
│         ▼                      ▼                             │
│  ┌──────────────────────────────────────────────┐          │
│  │  RAG Platform Services                       │          │
│  │  - Qdrant (StatefulSet + PVC)               │          │
│  │  - Ollama (Deployment + PVC)                │          │
│  │  - Query Service (Deployment)               │          │
│  │  - UI (Deployment + Route)                  │          │
│  │  - Ingest (Job)                             │          │
│  └──────────────────────────────────────────────┘          │
└─────────────────────────────────────────────────────────────┘
```

**Key Features:**
- **Vault Secrets Operator:** Automatically syncs secrets from Vault to Kubernetes
- **Kubernetes Auth:** Services authenticate to Vault using ServiceAccount tokens
- **Secret Rotation:** Secrets refresh every 30s with automatic pod restarts
- **OpenShift Routes:** HTTPS ingress with TLS termination
- **Persistent Storage:** StatefulSets and PVCs for data persistence

See [OpenShift Deployment Architecture](docs/architecture/openshift-deployment.md) for detailed information.

### Quick Commands

```bash
# Check deployment status
task status:ocp

# View logs
task logs:ocp -- query-service

# Cleanup everything
task clean:ocp

# Stop CRC
task stop:ocp
```

---

## Production: Vault and Consul (Nomad)

For Nomad-based deployments, plaintext environment variables are replaced by
Vault-managed secrets and Consul-enforced mTLS.

### Vault Agent Credential Delivery

The `vault/` directory contains a ready-to-use configuration:

| File          | Purpose                                                   |
|---------------|-----------------------------------------------------------|
| `policy.hcl`  | Least-privilege read policy for `kv/data/rag/config`.    |
| `agent.hcl`   | Vault Agent with AppRole auth; renders secrets to disk.  |
| `config.tpl`  | Consul Template that renders env vars from KV.           |
| `setup.sh`    | Idempotent bootstrap: enables KV v2, writes placeholders, creates the AppRole role. |

**Flow:**

1. Run `vault/setup.sh` against your Vault cluster to bootstrap secrets
   and the AppRole role.
2. Deploy `vault/agent.hcl` as a sidecar. It authenticates with AppRole,
   fetches secrets from `kv/data/rag/config`, and renders them to
   `/vault/secrets/config.env`.
3. The application sources `/vault/secrets/config.env` at startup.
4. When secrets rotate, Vault Agent re-renders the file and sends
   `SIGHUP` to the main process for a zero-downtime reload.

### Consul Connect and SPIFFE

Consul Connect provides mTLS between all services using SPIFFE-compatible
X.509 SVIDs. Each service receives a certificate with a SPIFFE ID of the
form:

```
spiffe://<trust-domain>/ns/default/dc/dc1/svc/<service-name>
```

Intentions (L4/L7 authorization policies) restrict which services can
communicate. For example, the query service can reach Qdrant and Ollama,
but the UI can only reach the query service.

The Nomad job spec in `docs/jobs/rag-ingest.hcl` demonstrates the full
pattern: `vault` stanza for credential delivery, `connect` sidecar for
mTLS, and `template` block for rendering secrets into the task
environment.

> See the companion blog post for a detailed walkthrough of this
> architecture.

---

## Project Structure

```
rag-hashicorp-platform/
├── ingest/              # Batch ingestion pipeline
│   ├── ingest.py        # Main entry point
│   ├── chunker.py       # Markdown + HCL chunking strategies
│   ├── requirements.txt
│   └── Dockerfile
├── query-service/       # FastAPI /ask endpoint
│   ├── main.py
│   ├── requirements.txt
│   └── Dockerfile
├── ui/                  # Streamlit Q&A interface
│   ├── ask.py
│   ├── requirements.txt
│   └── Dockerfile
├── k8s/                 # OpenShift/Kubernetes manifests
│   ├── base/            # Base deployments
│   │   ├── qdrant-statefulset.yaml
│   │   ├── ollama-deployment.yaml
│   │   ├── query-service-deployment.yaml
│   │   ├── ui-deployment.yaml
│   │   └── ingest-job.yaml
│   └── vault/           # Vault and VSO configuration
│       ├── vault-dev.yaml
│       ├── vault-connection.yaml
│       ├── vault-auth.yaml
│       ├── qdrant-secret.yaml
│       └── ollama-secret.yaml
├── vault/               # Production credential delivery (Nomad)
│   ├── policy.hcl
│   ├── agent.hcl
│   ├── config.tpl
│   └── setup.sh
├── scripts/             # Automation scripts
│   ├── configure-vault.sh  # Vault setup for OpenShift
│   ├── ask.sh
│   └── walkthrough.sh
├── docs/                # Document corpus
│   ├── architecture/    # Architecture documentation
│   │   └── openshift-deployment.md
│   ├── configuration/   # Setup guides
│   │   ├── crc-prerequisites.md
│   │   └── vault-vso-integration.md
│   ├── runbooks/        # Operational runbooks
│   ├── policies/        # Vault HCL policies
│   └── jobs/            # Nomad HCL job specs
├── docker-compose.yml   # Docker Compose (local dev)
├── Taskfile.yml         # Docker Compose automation
├── Taskfile-openshift.yml  # OpenShift automation
├── .env.example
└── .gitignore
```

---

## License

MIT
