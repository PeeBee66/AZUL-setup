# AZUL Installation Guide - Homelab (KUBS Cluster)

**Date**: 2026-02-11 (original), 2026-02-14 (rewritten)
**Cluster**: KUBS (5-node Talos Linux K8s v1.34.3 on Proxmox)
**Source Repo**: https://github.com/AustralianCyberSecurityCentre/azul-app (cloned to /data/AZUL/azul-app)
**Source Docs**: https://australiancybersecuritycentre.github.io/azul/developer-guide/components/core/app/
**AZUL Version**: 10.0.0-unstable (infra chart), 9.0.0 (app chart)
**Purpose**: Online install with full documentation for future offline replication

---

## Table of Contents

1. [Overview](#overview)
2. [Complete File Inventory](#complete-file-inventory)
3. [Prerequisites](#prerequisites)
4. [DNS Records](#dns-records)
5. [Upstream Chart Patches](#upstream-chart-patches)
6. [Certificate Management](#certificate-management)
7. [Step-by-Step Manual Install](#step-by-step-manual-install)
   - [Stage 1: Infrastructure](#stage-1-infrastructure)
   - [Stage 2: Core Application](#stage-2-core-application)
   - [Stage 3: Plugins](#stage-3-plugins)
8. [Backup & Restore](#backup--restore)
9. [Teardown](#teardown)
10. [Full Lifecycle Workflow](#full-lifecycle-workflow)
11. [Container Images Required](#container-images-required)
12. [Credentials Summary](#credentials-summary)
13. [Issues & Changes Log](#issues--changes-log)
14. [Known Gotchas](#known-gotchas)
15. [Homelab Adaptations](#homelab-adaptations)
16. [Offline Install Checklist](#offline-install-checklist)

---

## Overview

AZUL is a malware repository, analytical engine, and clustering suite by the Australian Cyber Security Centre (ACSC/ASD). It runs on Kubernetes with:
- **Kafka** (event store via Strimzi operator)
- **OpenSearch** (search/indexing via OpenSearch K8s operator)
- **MinIO** (S3-compatible object storage)
- **Keycloak** (OIDC authentication)
- **Redis** (in-memory cache, bundled in app chart)

### 3-Stage Installation Process

1. **Infrastructure** (Stage 1): Operators + Kafka, OpenSearch, MinIO, Keycloak, Postgres → `azul-infra` namespace
2. **Core Application** (Stage 2): Dispatchers, metastore, restapi, webui, redis → `azul` namespace (13 pods)
3. **Plugins** (Stage 3): Analysis plugins (office, tika, generic, yara-x, suricata, maco) → `azul` namespace (50 pods)

---

## Complete File Inventory

All files needed to deploy and manage AZUL. Everything is included in this repo — no internet access required.

### Upstream Chart Repository (included, pre-patched)

The upstream `azul-app/` repo is included at the `azul-9.0.0` tag with all 3 template patches already applied. No need to clone separately.

```
azul-app/                              # azul-9.0.0 tag, pre-patched
├── azul/                              # Main app Helm chart (Stage 2+3)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
├── infra/                             # Infrastructure Helm chart (Stage 1)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── ca-certificates                # Mozilla CA bundle (patched with Test CA by setup-certs.sh)
│   ├── charts/                        # Bundled monitoring deps (all disabled for homelab)
│   └── templates/
│       ├── keycloak/keycloak.yaml     # PATCHED: ingress port 80→8080
│       └── opensearch.yaml            # PATCHED: additionalVolumes + additionalConfig support
└── cosign.pub
```

### Operator Helm Charts (included as .tgz)

```
charts/
├── strimzi-kafka-operator-helm-3-chart-0.50.0.tgz    # Strimzi Kafka Operator
└── opensearch-operator-2.8.0.tgz                     # OpenSearch K8s Operator
```

The deploy script installs these directly from the local `.tgz` files — no `helm repo add` needed.

### Custom Configuration Files

| File | Purpose | Sensitive |
|------|---------|-----------|
| `azul-infra-values.yaml` | Infra chart overrides (Kafka, OpenSearch, MinIO, Keycloak config, security config, internal users) | No |
| `azul-values.yaml` | App chart overrides — Stage 3 (core + all plugins, `pluginsEnabled: true`) | No |
| `azul-values-core.yaml` | App chart overrides — Stage 2 (core only, `pluginsEnabled: false`) | No |
| `.azul-credentials` | Generated K8s secret values (MinIO keys, OpenSearch passwords, Keycloak admin) | **YES** (mode 600) |
| `setup-keycloak.sh` | Keycloak realm/client/scope/user configuration via Admin API | No |
| `docker-compose-backup.yaml` | External MinIO for backup (docker/podman on host, ports 9100/9101) | No |

### Automation Scripts

| File | Purpose |
|------|---------|
| `scripts/Infra_install.sh` | Standalone infra install (10 steps, `--step N` resume, `--check` mode, full image/registry reference) |
| `scripts/azul-deploy.sh` | 3-stage deploy with health checks (infra → app → plugins) |
| `scripts/azul-teardown.sh` | Complete Azul removal (helm releases, PVCs, namespaces, operators, CRDs, CoreDNS) |
| `scripts/azul-backup.sh` | Start/stop/status continuous backup to external MinIO |
| `scripts/azul-restore.sh` | Restore from external MinIO backup (Kafka event replay) |
| `scripts/setup-certs.sh` | Certificate management (patch CA into chart, create TLS certs) |

### Generated at Runtime (not committed)

| File | Created By | Purpose |
|------|-----------|---------|
| `azul-app/infra/ca-certificates` (patched) | `setup-certs.sh` | Test CA appended to chart's Mozilla CA bundle |

---

## Prerequisites

Before starting the install, ensure:

- [x] Kubernetes cluster running (v1.34.3 Talos Linux)
- [x] cert-manager installed (v1.16.2)
- [x] nginx ingress controller installed (DaemonSet with hostPort 80/443)
- [x] `kubectl`, `helm`, `python3`, `curl`, `openssl` in PATH
- [x] `python3 -c "import bcrypt"` works (`pip3 install bcrypt`)
- [x] Docker or Podman available on the host (for external MinIO backup target)
- [x] Talos PodSecurity exemptions applied for: `kafka`, `opensearch-operator`, `azul-infra`, `azul`
- [x] Pi-hole DNS records created (see DNS Records section)
- [x] This repo cloned to `/data/AZUL/` (includes azul-app charts, operator .tgz files, all scripts)
- [x] `.azul-credentials` file created with generated passwords (mode 600)

### Talos PodSecurity Exemptions

Add `kafka`, `opensearch-operator`, `azul-infra`, `azul` to the exempted namespaces list. Use JSON patch (never YAML merge — it causes duplicates that crash the API server):

```bash
talosctl --talosconfig /home/kp-admin/KUBS/talosconfig -n 192.168.66.201 patch mc --patch '[{"op":"replace","path":"/cluster/apiServer/admissionControl","value":[{"name":"PodSecurity","configuration":{"apiVersion":"pod-security.admission.config.k8s.io/v1alpha1","kind":"PodSecurityConfiguration","defaults":{"enforce":"baseline","enforce-version":"latest","audit":"restricted","audit-version":"latest","warn":"restricted","warn-version":"latest"},"exemptions":{"namespaces":["kube-system","ingress-nginx","unifi","home-assistant","local-path-storage","keel","headlamp","homarr","teslamate","kafka","opensearch-operator","azul-infra","azul"],"runtimeClasses":[],"usernames":[]}}}]}]'
```

### Credentials File

Generate `/data/AZUL/.azul-credentials` (mode 600) with **static** passwords. Use `Infra_install.sh --creds` to generate automatically, or create manually:

```bash
cat > /data/AZUL/.azul-credentials <<EOF
# AZUL Infrastructure Credentials — SENSITIVE — DO NOT COMMIT
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# These are STATIC values. Do not change after secrets are created in cluster.

## MinIO (Main S3 storage)
S3_ACCESS_KEY=$(openssl rand -hex 16)
S3_SECRET_KEY=$(openssl rand -hex 32)

## OpenSearch Admin
OS_ADMIN_USER=admin
OS_ADMIN_PASS=$(openssl rand -base64 24)

## OpenSearch Dashboard (kibanaserver)
OS_DASH_USER=kibanaserver
OS_DASH_PASS=$(openssl rand -base64 24)

## Keycloak
KC_DB_PASSWORD=$(openssl rand -base64 24)
KC_ADMIN_USER=admin
KC_ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF

chmod 600 /data/AZUL/.azul-credentials
```

**Important**: Use unquoted `EOF` (not `'EOF'`) so `$(openssl ...)` expands at creation time, producing static values. Once created, the file contains fixed passwords — safe to re-source without generating different values each time.

### Chart Version

The included `azul-app/` directory is at the stable `azul-9.0.0` tag with all 3 template patches pre-applied. No checkout or patching needed.

**Note**: The upstream `main` branch uses `10.0.0-unstable` with image tags not publicly available on Docker Hub. The stable `9.0.0` tag is what we use — all `asdazul/*` images are available on Docker Hub at this tag.

---

## DNS Records

### Pi-hole Local DNS Records

Add these in Pi-hole Admin → Local DNS → DNS Records:

| Hostname | IP | Purpose |
|----------|-----|---------|
| `azul.kp.local` | `192.168.66.201` | AZUL Web UI |
| `keycloak-azul.kp.local` | `192.168.66.201` | Keycloak auth |
| `opensearch-azul.kp.local` | `192.168.66.201` | OpenSearch Dashboards |
| `minio-azul.kp.local` | `192.168.66.201` | MinIO Console |
| `minio-api-azul.kp.local` | `192.168.66.201` | MinIO API |

Without these, the browser OIDC login flow fails — the browser redirects to `keycloak-azul.kp.local` for authentication and can't resolve it.

### CoreDNS Hosts Block

Pods inside the cluster also need to resolve `*.kp.local`. The deploy script adds this automatically, or add manually:

```bash
kubectl edit configmap coredns -n kube-system
```

Add inside the `.:53 { }` block, before the `forward` directive:

```
    hosts {
        192.168.66.201 keycloak-azul.kp.local
        192.168.66.201 opensearch-azul.kp.local
        192.168.66.201 azul.kp.local
        fallthrough
    }
```

Then restart: `kubectl rollout restart deployment coredns -n kube-system`

**Note**: The management server (`kp-svr-01`, `192.168.66.41`) uses `1.1.1.1`/`8.8.8.8` as DNS, not Pi-hole. For server-side testing, use `curl --resolve` or add entries to `/etc/hosts`.

---

## Upstream Chart Patches

The upstream infra chart templates need 3 modifications. These must be re-applied if you re-clone the repo.

### Patch 1: Keycloak Ingress Port Fix

**File**: `azul-app/infra/templates/keycloak/keycloak.yaml`
**Issue**: Ingress backend port was `80`, but Keycloak service uses port `8080`
**Fix**: Change `number: 80` to `number: 8080` at the ingress backend service port.

### Patch 2: OpenSearch Dashboard additionalVolumes Support

**File**: `azul-app/infra/templates/opensearch.yaml`
**Issue**: Template didn't pass `dashboard.additionalVolumes` to the OpenSearchCluster CRD.
**Fix**: Add after the `env` block (around line 258):

```yaml
{{- if .Values.opensearch.dashboard.additionalVolumes }}
    additionalVolumes:
{{ .Values.opensearch.dashboard.additionalVolumes | toYaml | nindent 6 }}
{{- end }}
```

### Patch 3: OpenSearch General additionalConfig Support

**File**: `azul-app/infra/templates/opensearch.yaml`
**Issue**: Template didn't pass `general.additionalConfig` to the CRD.
**Fix**: Add after `setVMMaxMapCount` (around line 175):

```yaml
{{- if .Values.opensearch.general.additionalConfig }}
    additionalConfig:
{{ .Values.opensearch.general.additionalConfig | toYaml | nindent 6 }}
{{- end }}
```

---

## Certificate Management

### How It Works

AZUL uses a self-signed CA ("Test CA") created by cert-manager during the infra chart install. This CA signs:
- **Keycloak TLS cert** (`keycloak-tls`) — for HTTPS on `keycloak-azul.kp.local`
- **Azul Web TLS cert** (`azul-web-tls`) — for HTTPS on `azul.kp.local`
- **OpenSearch inter-node TLS** — managed by the OpenSearch operator

OpenSearch's OIDC configuration references a `ca-certificates` file to validate Keycloak's TLS cert during JWT verification. This file is generated from the infra chart's bundled `ca-certificates` file (3585 lines of Mozilla root CAs). The Test CA must be included in this bundle, otherwise OpenSearch can't validate Keycloak's cert and OIDC auth fails with "Authentication finally failed".

### The `setup-certs.sh` Script

The script at `/data/AZUL/scripts/setup-certs.sh` manages all certificate operations. It can be run standalone or sourced by other scripts.

**Key approach**: The Test CA is patched directly into the chart's `ca-certificates` file on disk. This means every future `helm install/upgrade azul-infra` automatically includes the Test CA in the OpenSearch certs configmap — no post-install patching needed.

#### Standalone Commands

```bash
# Full certificate setup (all steps)
./scripts/setup-certs.sh all

# Individual steps:
./scripts/setup-certs.sh patch-ca    # Patch Test CA into chart's ca-certificates file
./scripts/setup-certs.sh keycloak    # Create Keycloak TLS cert (cert-manager Certificate)
./scripts/setup-certs.sh azul        # Create azul namespace certs (web TLS + CA configmap)
```

#### Functions (when sourced by other scripts)

```bash
source /data/AZUL/scripts/setup-certs.sh

wait_for_ca            # Wait for cert-manager to issue the CA secret
patch_ca_into_chart    # Append Test CA to chart's ca-certificates file (idempotent)
create_keycloak_cert   # Create Keycloak TLS cert via cert-manager
create_azul_web_cert   # Create azul-web-tls cert (copies CA to azul namespace, creates Issuer + Certificate)
create_ca_configmap    # Create azul-ca-cert configmap from cluster CA secret
```

#### Certificate Flow During Deploy

1. `helm install azul-infra` → cert-manager creates the self-signed CA (`azul-opensearch-ca-cert` secret)
2. `setup-certs.sh patch-ca` → Extracts CA PEM, appends to `azul-app/infra/ca-certificates` file on disk
3. `helm upgrade azul-infra` → Regenerates `azul-opensearch-certs` configmap, now including the Test CA
4. `setup-certs.sh keycloak` → Creates cert-manager Certificate for `keycloak-azul.kp.local` (signed by Test CA)
5. OpenSearch restarts → picks up the new configmap with Test CA, can now validate Keycloak's cert
6. `setup-certs.sh azul` → Copies CA to `azul` namespace, creates Issuer + Certificate for `azul.kp.local`

**Important**: After `patch_ca_into_chart` runs once, the Test CA is permanently in the chart file. All future `helm upgrade azul-infra` operations preserve it automatically. No need to re-append after helm upgrades.

---

## Step-by-Step Manual Install

This section provides every command needed for a manual install. The deploy script (`azul-deploy.sh all`) automates all of this.

### Stage 1: Infrastructure

#### 1.1 Install Strimzi Kafka Operator

```bash
helm install strimzi-kafka-operator /data/AZUL/charts/strimzi-kafka-operator-helm-3-chart-0.50.0.tgz \
  --namespace kafka --create-namespace \
  --set watchAnyNamespace=true \
  --timeout 3m

# Wait for operator pod
kubectl wait --for=condition=ready pod -l name=strimzi-cluster-operator -n kafka --timeout=120s
```

**Note**: Use `watchAnyNamespace=true`, NOT `watchNamespaces="{*}"` (YAML parse error). The chart is installed from the local `.tgz` file — no `helm repo add` needed.

#### 1.2 Install OpenSearch Operator

```bash
helm install opensearch-operator /data/AZUL/charts/opensearch-operator-2.8.0.tgz \
  --namespace opensearch-operator --create-namespace \
  --timeout 3m

# Wait for operator pod
kubectl wait --for=condition=ready pod -l control-plane=controller-manager -n opensearch-operator --timeout=120s
```

#### 1.3 Create azul-infra Namespace and Secrets

```bash
kubectl create namespace azul-infra

# Source credentials
source <(grep -v '^#' /data/AZUL/.azul-credentials | grep -v '^$' | sed 's/^/export /')

# MinIO access keys
kubectl create secret generic s3-keys -n azul-infra \
  --from-literal=accesskey="$S3_ACCESS_KEY" \
  --from-literal=secretkey="$S3_SECRET_KEY"

# OpenSearch admin credentials
kubectl create secret generic azul-cluster-admincredentials -n azul-infra \
  --from-literal=username=admin \
  --from-literal=password="$OS_ADMIN_PASS"

# OpenSearch dashboard credentials
kubectl create secret generic azul-cluster-dashboardcredentials -n azul-infra \
  --from-literal=username=kibanaserver \
  --from-literal=password="$OS_DASH_PASS"

# Keycloak secrets
kubectl create secret generic keycloak -n azul-infra \
  --from-literal=DB_PASSWORD="$KC_DB_PASSWORD" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD"
```

#### 1.4 Deploy Infra Helm Chart

```bash
helm install azul-infra /data/AZUL/azul-app/infra \
  -n azul-infra -f /data/AZUL/azul-infra-values.yaml --timeout 10m
```

#### 1.5 Patch Test CA into Chart Bundle

After helm install, cert-manager creates the self-signed CA. Patch it into the chart file so future helm upgrades include it:

```bash
# Wait for CA secret to be created by cert-manager
kubectl get secret azul-opensearch-ca-cert -n azul-infra

# Run the certificate setup script (patches CA into chart file)
/data/AZUL/scripts/setup-certs.sh patch-ca
```

**What this does**: Extracts the CA PEM from the cluster secret and appends it to `azul-app/infra/ca-certificates`. After this, the Test CA is permanently part of the chart.

#### 1.6 Wait for Infrastructure Pods

Pods come up in order: Kafka → MinIO → Postgres → Keycloak → OpenSearch.

```bash
kubectl wait --for=condition=ready pod -l strimzi.io/component-type=kafka -n azul-infra --timeout=300s
kubectl wait --for=condition=ready pod -l app=minio -n azul-infra --timeout=180s
kubectl wait --for=condition=ready pod -l app=postgres -n azul-infra --timeout=180s
kubectl wait --for=condition=ready pod -l app=keycloak -n azul-infra --timeout=300s
```

OpenSearch usually needs the unsafe-bootstrap fix (see next step).

#### 1.7 OpenSearch Single-Node Unsafe Bootstrap

**Why**: The OpenSearch operator creates a temporary `bootstrap-0` pod for initial cluster formation. After security init, the operator removes it. For single-node clusters, this breaks the voting configuration — the remaining data node loses quorum, showing `cluster_manager_not_discovered_exception`.

Check if OpenSearch is stuck (not Ready after 30+ seconds):

```bash
kubectl get pod azul-opensearch-nodes-0 -n azul-infra
```

If not Ready, run the unsafe-bootstrap fix:

```bash
# 1. Scale down operator to prevent interference
kubectl scale deployment opensearch-operator-controller-manager \
  -n opensearch-operator --replicas=0
sleep 5

# 2. Scale down OpenSearch StatefulSet
kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=0
sleep 15

# 3. Run unsafe-bootstrap via temporary Job
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: opensearch-unsafe-bootstrap
  namespace: azul-infra
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: bootstrap
        image: docker.io/opensearchproject/opensearch:3.2.0
        command: ["/bin/bash", "-c", "echo 'y' | /usr/share/opensearch/bin/opensearch-node unsafe-bootstrap"]
        volumeMounts:
        - name: data
          mountPath: /usr/share/opensearch/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: data-azul-opensearch-nodes-0
EOF

# 4. Wait for Job completion
kubectl wait --for=condition=complete job/opensearch-unsafe-bootstrap \
  -n azul-infra --timeout=120s

# 5. Clean up and restore
kubectl delete job opensearch-unsafe-bootstrap -n azul-infra
kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=1
kubectl scale deployment opensearch-operator-controller-manager \
  -n opensearch-operator --replicas=1

# 6. Wait for OpenSearch to be ready
kubectl wait --for=condition=ready pod/azul-opensearch-nodes-0 -n azul-infra --timeout=180s
```

**Note**: This is needed for single-node clusters only. With 3+ replicas, the operator's bootstrap removal doesn't break quorum. It's also needed after EVERY OpenSearch pod restart (the node ID changes each time).

#### 1.8 Configure CoreDNS

Add hosts entries for cluster-internal DNS resolution (see [DNS Records](#dns-records) section).

The deploy script does this automatically. To do it manually:

```bash
kubectl edit configmap coredns -n kube-system
# Add the hosts block inside .:53 {}, before forward
kubectl rollout restart deployment coredns -n kube-system
```

#### 1.9 Create Keycloak TLS Certificate

```bash
/data/AZUL/scripts/setup-certs.sh keycloak
```

Or manually:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-tls
  namespace: azul-infra
spec:
  secretName: keycloak-tls
  issuerRef:
    name: azul-opensearch-ca-issuer
    kind: Issuer
  dnsNames:
    - keycloak-azul.kp.local
  duration: 8760h
  renewBefore: 720h
EOF

kubectl wait --for=condition=Ready certificate/keycloak-tls -n azul-infra --timeout=60s
```

#### 1.10 Bake Test CA into OpenSearch

Now that the chart file has been patched (step 1.5), run a helm upgrade to update the configmap:

```bash
helm upgrade azul-infra /data/AZUL/azul-app/infra \
  -n azul-infra -f /data/AZUL/azul-infra-values.yaml --timeout 5m
```

OpenSearch needs to restart to pick up the updated configmap. Since single-node requires unsafe-bootstrap after every restart, use the bootstrap procedure from step 1.7 again:

```bash
# Scale down, run unsafe-bootstrap, scale up (same as step 1.7)
kubectl scale deployment opensearch-operator-controller-manager -n opensearch-operator --replicas=0
kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=0
sleep 15
# ... (run the unsafe-bootstrap Job from step 1.7) ...
kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=1
kubectl scale deployment opensearch-operator-controller-manager -n opensearch-operator --replicas=1
kubectl wait --for=condition=ready pod/azul-opensearch-nodes-0 -n azul-infra --timeout=180s
```

**Verify** the Test CA is in the bundle:

```bash
kubectl exec azul-opensearch-nodes-0 -n azul-infra -- \
  grep "Test CA" /usr/share/opensearch/config/certs/ca-certificates
```

#### 1.11 Configure Keycloak Realm and Users

```bash
bash /data/AZUL/setup-keycloak.sh
```

This creates:
- **Realm**: `azul` (enabled, accessTokenLifespan=300)
- **Realm Roles**: azul-access, azul_read, azul_admin, azul_write, s-any, s-official
- **Groups**: general, opensearch-admins
- **Client Scope "azul"**: With realm-roles mapper + subject (sub) mapper (CRITICAL for Keycloak 26.x)
- **Client Scope "audience"**: With `oidc-audience-mapper` (`included.client.audience: azul-web`)
- **Client "azul-web"**: Public client for Web UI, scopes: `openid profile email azul audience` (default), `offline_access roles` (optional)
- **Client "opensearch-dashboards"**: Confidential client (secret: `opensearch-dashboards-secret`)
- **Client "azul-service"**: Service account client
- **Test User**: `basic` / `basic12345` (all azul roles, general group)
- **Admin User**: `azuladmin` / `admin12345` (all azul roles, opensearch-admins group)

**Note**: The script uses `kubectl port-forward` internally. If it times out, verify completion in the Keycloak Admin Console at `https://keycloak-azul.kp.local`.

#### 1.12 Verify Stage 1

```bash
# All infra pods running
kubectl get pods -n azul-infra

# Keycloak realm accessible (expect 200)
curl -k -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: keycloak-azul.kp.local" https://192.168.66.201/realms/azul

# OpenSearch cluster health (expect green)
OS_ADMIN_PASS=$(grep OS_ADMIN_PASS /data/AZUL/.azul-credentials | cut -d= -f2)
kubectl exec azul-opensearch-nodes-0 -n azul-infra -- \
  curl -sf -u "admin:${OS_ADMIN_PASS}" -k https://localhost:9200/_cluster/health \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Status: {d[\"status\"]}, Nodes: {d[\"number_of_nodes\"]}')"
```

Expected infra pods:

| Pod | Ready | Component |
|-----|-------|-----------|
| azul-kafka-nodes-0 | 1/1 | Kafka broker (KRaft mode) |
| azul-kafka-entity-operator-* | 2/2 | Strimzi entity operator |
| azul-kafka-kafka-exporter-* | 1/1 | Kafka metrics exporter |
| azul-kafka-kafkactl-* | 1/1 | Kafka CLI tool |
| azul-opensearch-nodes-0 | 1/1 | OpenSearch data+cluster_manager |
| azul-opensearch-dashboards-* | 1/1 | OpenSearch Dashboards (with OIDC) |
| keycloak-* (x2) | 1/1 | Keycloak HA (2 replicas) |
| postgres-* | 1/1 | PostgreSQL (for Keycloak) |
| s3-store-minio-0 | 1/1 | MinIO object storage |

---

### Stage 2: Core Application

#### 2.1 Create azul Namespace and Secrets

```bash
kubectl create namespace azul

# Source credentials
source <(grep -v '^#' /data/AZUL/.azul-credentials | grep -v '^$' | sed 's/^/export /')

# Copy MinIO keys from infra namespace
kubectl get secret s3-keys -n azul-infra -o json \
  | python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata']['namespace'] = 'azul'
for k in ('resourceVersion', 'uid', 'creationTimestamp'):
    s['metadata'].pop(k, None)
s['metadata'].pop('annotations', None)
print(json.dumps(s))
" | kubectl apply -f -
```

**Redis secret** — MUST include `redis-username`, `redis-password`, AND `password` keys (Issue #22):

```bash
REDIS_PASS=$(openssl rand -base64 16)
kubectl create secret generic redis -n azul \
  --from-literal=redis-username="" \
  --from-literal=redis-password="$REDIS_PASS" \
  --from-literal=password="$REDIS_PASS"
```

**Metastore writer credentials** — bcrypt hash MUST match `azul-infra-values.yaml`:

```bash
# Generate new writer password
WRITER_PASS=$(openssl rand -base64 16)
kubectl create secret generic metastore-creds -n azul \
  --from-literal=writer="$WRITER_PASS"

# Generate bcrypt hash and update azul-infra-values.yaml
WRITER_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${WRITER_PASS}', bcrypt.gensalt()).decode())")
sed -i "s|hash: \"\\\$2b\\\$.*\"|hash: \"${WRITER_HASH}\"|" /data/AZUL/azul-infra-values.yaml

# Apply the updated hash to OpenSearch (helm upgrade preserves Test CA since it's baked into chart)
helm upgrade azul-infra /data/AZUL/azul-app/infra \
  -n azul-infra -f /data/AZUL/azul-infra-values.yaml --timeout 5m
```

**S3 backup keys** (for future backup/restore operations):

```bash
kubectl create secret generic s3-backup-keys -n azul \
  --from-literal=access_key="azul-backup" \
  --from-literal=secret_key="azul-backup-secret"
```

#### 2.2 Create Certificates for azul Namespace

```bash
/data/AZUL/scripts/setup-certs.sh azul
```

Or manually:

```bash
# Copy CA secret from azul-infra to azul namespace
kubectl get secret azul-opensearch-ca-cert -n azul-infra -o json \
  | python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata'] = {'name': 'azul-opensearch-ca-cert', 'namespace': 'azul'}
print(json.dumps(s))
" | kubectl apply -f -

# Create namespace-scoped CA Issuer
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: azul-ca-issuer
  namespace: azul
spec:
  ca:
    secretName: azul-opensearch-ca-cert
EOF

# Create azul-web-tls Certificate
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: azul-web-tls
  namespace: azul
spec:
  secretName: azul-web-tls
  issuerRef:
    name: azul-ca-issuer
    kind: Issuer
  dnsNames:
    - azul.kp.local
  duration: 8760h
  renewBefore: 720h
EOF

kubectl wait --for=condition=Ready certificate/azul-web-tls -n azul --timeout=30s

# Create CA configmap (for pods that need to trust the CA)
kubectl get secret azul-opensearch-ca-cert -n azul-infra \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca-cert.pem
kubectl create configmap azul-ca-cert -n azul --from-file=ca.crt=/tmp/ca-cert.pem
rm -f /tmp/ca-cert.pem
```

#### 2.3 Deploy Core App (No Plugins)

```bash
helm install azul /data/AZUL/azul-app/azul \
  -n azul -f /data/AZUL/azul-values-core.yaml --timeout 10m
```

Uses `azul-values-core.yaml` with `pluginsEnabled: false` — deploys only the 13 core pods.

#### 2.4 Wait for Core Pods

```bash
# Wait for all pods (13 expected)
kubectl wait --for=condition=ready pods --all -n azul --timeout=300s
kubectl get pods -n azul
```

**Note**: Metastore pods may CrashLoop 2-3 times on first startup while dispatchers initialise Kafka connections. This is normal and self-resolves within ~2 minutes.

Expected core pods (13):

| Pod | Component |
|-----|-----------|
| azul-redis-master-0 | Redis cache |
| docs-* | API documentation (nginx) |
| dp-metastore-events-* | Dispatcher: metastore event routing |
| dp-metastore-streams-* | Dispatcher: metastore stream routing |
| dp-plugin-events-* | Dispatcher: plugin event routing |
| dp-plugin-streams-* | Dispatcher: plugin stream routing |
| dp-lost-tasks-* | Lost task recovery |
| ms-ageoff-* | Metastore: data age-off |
| ms-ingest-binary-* | Metastore: binary ingest to OpenSearch |
| ms-ingest-plugin-* | Metastore: plugin result ingest |
| ms-ingest-status-* | Metastore: status ingest |
| restapi-0 | REST API server (uvicorn) |
| webui-* | Angular web UI (nginx) |

#### 2.5 Verify Stage 2

```bash
# Web UI (expect 302)
curl -k -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: azul.kp.local" https://192.168.66.201/

# OAuth token for test user
TOKEN=$(curl -k -s -X POST "https://keycloak-azul.kp.local/realms/azul/protocol/openid-connect/token" \
  --resolve "keycloak-azul.kp.local:443:192.168.66.201" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=basic&password=basic12345&grant_type=password&client_id=azul-web' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

# API /users/me with token (expect 200)
curl -k -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: azul.kp.local" \
  -H "Authorization: Bearer $TOKEN" \
  "https://192.168.66.201/api/v0/users/me"
```

---

### Stage 3: Plugins

#### 3.1 Upgrade with Full Values (Plugins Enabled)

```bash
helm upgrade azul /data/AZUL/azul-app/azul \
  -n azul -f /data/AZUL/azul-values.yaml --timeout 10m
```

Uses `azul-values.yaml` with `pluginsEnabled: true` and all plugin groups defined.

#### 3.2 Scale-to-Zero/One Workaround (LimitRange CPU)

New plugin pods may inherit stale LimitRange defaults. Scale to 0 then 1 to force recreation with current limits:

```bash
# Get all plugin deployment names
PLUGINS=$(kubectl get deployments -n azul --no-headers -o custom-columns=NAME:.metadata.name \
  | grep -E "^plugin-")

# Scale to 0
echo "$PLUGINS" | xargs -I{} kubectl scale deployment {} -n azul --replicas=0

# Wait for termination
sleep 30

# Scale to 1
echo "$PLUGINS" | xargs -I{} kubectl scale deployment {} -n azul --replicas=1
```

#### 3.3 Wait for All Pods

```bash
# Wait for images to pull and pods to start (may take 5-10 minutes)
kubectl get pods -n azul --watch

# Count pods (expect ~63)
kubectl get pods -n azul --no-headers | wc -l

# Check for CrashLoopBackOff (expect none)
kubectl get pods -n azul --no-headers | grep CrashLoopBackOff

# Check for Pending (ghidra may stay Pending — 500m CPU request)
kubectl get pods -n azul --no-headers | grep Pending
```

#### 3.4 Enabled Plugin Groups

| Group | Type | Pods | Description |
|-------|------|------|-------------|
| office | standard | 8 | Office doc analysis: DDE, decrypt, macros, MIME, OLE, OpenXML, RTF, SYLK |
| tika | standard | 1 (2 containers) | Apache Tika metadata extraction with sidecar server |
| generic | standard | 40 | LIEF (ELF/PE/Mach-O), PDF tools, email, exiftool, FLOSS, Ghidra, CAPA, unbox, etc. |
| yara-x | yara-x | 0 | Enabled but no sources (public YARA repos incompatible with YARA-X syntax) |
| suricata | suricata | 0 | Enabled but no rule sources configured yet |
| maco | maco | 0 | Enabled but no extractor sources configured yet |

**Disabled groups**: assemblyline (needs external instance), dynamic/CAPE (needs sandbox), virustotal (needs API key), nsrl (needs 256Gi PVC), retrohunt (needs 1000Gi PVC), report-feeds (not open-sourced).

#### 3.5 Resource Adjustments for Homelab

- **LimitRange default CPU request**: 10m per container (reduced from 50m — light plugins are mostly idle)
- **Heavy plugins reduced memory**: mandiant-capa (2Gi/4Gi), floss (2Gi/4Gi), ghidra (2Gi/4Gi), exiftool (1Gi/2Gi), unbox (2Gi/4Gi), entrypointcheck (200Mi/2Gi)
- **Tika**: Explicit 10m CPU / 200Mi memory requests on both containers
- **Backup/restore pod**: 10m CPU / 512Mi memory requests (was 250m/2Gi, caused Pending on packed cluster)

---

## Backup & Restore

### Architecture

Azul has a **built-in backup mechanism** (`asdazul/backup:9.0.0`):
- **Backup mode**: Deploys a continuous pod that subscribes to Kafka topics and copies all events + binary streams to an external S3 endpoint
- **Restore mode**: Creates a one-shot Job that replays streams then events back into the system
- OpenSearch indices are **NOT backed up** — they rebuild automatically when events are replayed
- Redis is ephemeral cache — no backup needed
- Keycloak config is reproducible via `setup-keycloak.sh`

The backup target is an **external MinIO** running on the host machine (outside K8s), managed via docker-compose.

### External MinIO Setup

**File**: `/data/AZUL/docker-compose-backup.yaml`

| Setting | Value |
|---------|-------|
| S3 API port | 9100 (host) → 9000 (container) |
| Console port | 9101 |
| Credentials | `azul-backup` / `azul-backup-secret` |
| Data directory | `/data/backups/azul-minio/` |
| Console URL | http://192.168.66.41:9101 |

```bash
# Start external MinIO
docker compose -f /data/AZUL/docker-compose-backup.yaml up -d
# Or: podman-compose -f /data/AZUL/docker-compose-backup.yaml up -d

# Verify healthy
curl -sf http://localhost:9100/minio/health/live && echo "OK"
```

### Backup Configuration in azul-values.yaml

```yaml
recovery:
  mode: "off"                              # off | backup | restore
  restoreType: "all"
  externalS3Endpoint: "192.168.66.41:9100" # Host IP:port (NO http/https prefix)
  externalS3Secure: "false"                # Plain HTTP for local MinIO
  label: "01"                              # Changing label starts fresh backup
  bucketNamePrefix: "azul-backup-"         # Creates: azul-backup-01-streams, azul-backup-01-events
```

K8s secret `s3-backup-keys` in azul namespace provides `access_key` and `secret_key`.

### Using the Backup Script

```bash
# Start backup (starts external MinIO + deploys backup pod)
/data/AZUL/scripts/azul-backup.sh start

# Check backup progress
/data/AZUL/scripts/azul-backup.sh status

# Stop backup (removes backup pod, MinIO data preserved)
/data/AZUL/scripts/azul-backup.sh stop
```

### Using the Restore Script

```bash
# Check backup status without restoring
/data/AZUL/scripts/azul-restore.sh --check

# Restore from latest backup label
/data/AZUL/scripts/azul-restore.sh

# Restore from specific label
/data/AZUL/scripts/azul-restore.sh --label 02
```

The restore script:
1. Ensures external MinIO is running
2. Verifies backup data exists
3. Sets `recovery.mode: "restore"` in values
4. Runs `helm upgrade` to create a restore Job
5. Monitors Job completion (up to 30 minutes)
6. Resets `recovery.mode: "off"`

### Manual Backup/Restore Commands

If not using the scripts:

```bash
# === BACKUP ===
# 1. Start external MinIO
docker compose -f /data/AZUL/docker-compose-backup.yaml up -d

# 2. Create backup secret (if not exists)
kubectl create secret generic s3-backup-keys -n azul \
  --from-literal=access_key="azul-backup" \
  --from-literal=secret_key="azul-backup-secret"

# 3. Set mode to backup
sed -i 's/^  mode: .*/  mode: "backup"/' /data/AZUL/azul-values.yaml
helm upgrade azul /data/AZUL/azul-app/azul -n azul -f /data/AZUL/azul-values.yaml --timeout 5m

# 4. Verify backup pod is running
kubectl get pods -n azul -l "app.kubernetes.io/component=recovery-backup"
kubectl logs -n azul -l "app.kubernetes.io/component=recovery-backup" --tail=20

# 5. Stop backup
sed -i 's/^  mode: .*/  mode: "off"/' /data/AZUL/azul-values.yaml
helm upgrade azul /data/AZUL/azul-app/azul -n azul -f /data/AZUL/azul-values.yaml --timeout 5m

# === RESTORE ===
# 1. Set mode to restore
sed -i 's/^  mode: .*/  mode: "restore"/' /data/AZUL/azul-values.yaml
helm upgrade azul /data/AZUL/azul-app/azul -n azul -f /data/AZUL/azul-values.yaml --timeout 5m

# 2. Monitor Job
kubectl get jobs -n azul | grep restore
kubectl logs -n azul -l "app.kubernetes.io/component=recovery-restore" -f

# 3. Reset mode
sed -i 's/^  mode: .*/  mode: "off"/' /data/AZUL/azul-values.yaml
helm upgrade azul /data/AZUL/azul-app/azul -n azul -f /data/AZUL/azul-values.yaml --timeout 5m
```

---

## Teardown

### Using the Script

```bash
# Interactive (prompts for confirmation)
/data/AZUL/scripts/azul-teardown.sh

# Skip confirmation
/data/AZUL/scripts/azul-teardown.sh --force
```

### Manual Teardown

```bash
# 1. Uninstall Helm releases
helm uninstall azul -n azul --timeout 5m
helm uninstall azul-infra -n azul-infra --timeout 5m

# 2. Delete PVCs
kubectl delete pvc --all -n azul
kubectl delete pvc --all -n azul-infra

# 3. Delete namespaces
kubectl delete namespace azul --timeout=120s
kubectl delete namespace azul-infra --timeout=120s

# 4. Uninstall operators
helm uninstall strimzi-kafka-operator -n kafka --timeout 3m
helm uninstall opensearch-operator -n opensearch-operator --timeout 3m

# 5. Delete CRDs
kubectl get crds -o name | grep strimzi.io | xargs kubectl delete
kubectl get crds -o name | grep opensearch | xargs kubectl delete

# 6. Delete operator namespaces
kubectl delete namespace kafka --timeout=60s
kubectl delete namespace opensearch-operator --timeout=60s

# 7. Clean CoreDNS (remove azul hosts block)
kubectl edit configmap coredns -n kube-system
kubectl rollout restart deployment coredns -n kube-system
```

### Validate Clean State

```bash
kubectl get namespaces | grep -E "azul|kafka|opensearch"    # Should be empty
kubectl get crds | grep -E "strimzi|opensearch"             # Should be empty
helm list -A | grep -E "azul|strimzi|opensearch"            # Should be empty
```

---

## Full Lifecycle Workflow

Validated end-to-end on 2026-02-12.

### Script Overview — What Each Script Does and When to Use It

| Order | Script | What It Does | When to Use |
|-------|--------|--------------|-------------|
| 1 | `Infra_install.sh` | Standalone infra installer: generates credentials, installs operators (Strimzi + OpenSearch), creates namespace/secrets, deploys azul-infra Helm chart, patches CA certs, bootstraps OpenSearch, configures CoreDNS, creates Keycloak TLS cert, sets up Keycloak realm/users. 10 steps with `--step N` resume. | **First-time install** or when you want explicit control over the infra layer. Use `--check` to see current state, `--step 7` to resume from a specific step. |
| 2 | `azul-deploy.sh` | Full 3-stage automated deploy (infra → app → plugins) with health checks and Discord notifications. Infra stage does the same as `Infra_install.sh` but also includes Stage 2 (core app) and Stage 3 (plugins). | **Full deploy** (all 3 stages) or individual stages (`infra`, `app`, `plugins`). Preferred for repeat deploys where you want everything automated. |
| 3 | `azul-backup.sh` | Starts/stops/checks the built-in Azul backup mechanism. Starts an external MinIO on the host (docker-compose), creates the `s3-backup-keys` secret, toggles `recovery.mode` to `backup` via helm upgrade. Backup pod runs continuously, replicating Kafka events + binary streams to external S3. | **Before teardown** or on a regular schedule. Run `start` to begin, `status` to check, `stop` when done. |
| 4 | `azul-teardown.sh` | Complete removal: uninstalls Helm releases (azul, azul-infra), deletes all PVCs, deletes namespaces (azul, azul-infra), uninstalls operators (Strimzi, OpenSearch), deletes CRDs, cleans CoreDNS. | **Before a fresh redeploy** or decommissioning. Use `--force` to skip confirmation prompt. |
| 5 | `azul-restore.sh` | Restores data from external MinIO backup. Sets `recovery.mode` to `restore`, runs helm upgrade to create a restore Job that replays all events + streams. OpenSearch indices rebuild automatically. | **After a fresh deploy** (Stages 1+2 must be running). Use `--check` to verify backup data first. |
| — | `setup-certs.sh` | Certificate management helper. Patches CA into chart bundle, creates Keycloak/Azul TLS certs. Sourced by other scripts or run standalone. | **Called automatically** by `Infra_install.sh` and `azul-deploy.sh`. Run standalone to fix cert issues. |
| — | `setup-keycloak.sh` | Creates Keycloak realm, roles, groups, client scopes, clients, and test users via Admin API. | **Called automatically** by `Infra_install.sh` and `azul-deploy.sh`. Run standalone to reconfigure Keycloak. |

### Recommended Script Execution Order

```bash
# === FRESH INSTALL ===
# Option A: Use Infra_install.sh for infra, then azul-deploy.sh for app+plugins
/data/AZUL/scripts/Infra_install.sh             # Infra layer (10 steps)
/data/AZUL/scripts/azul-deploy.sh app            # Stage 2: core app (13 pods)
/data/AZUL/scripts/azul-deploy.sh plugins        # Stage 3: plugins (50 pods)

# Option B: Use azul-deploy.sh for everything
/data/AZUL/scripts/azul-deploy.sh all            # All 3 stages in one run

# === FULL LIFECYCLE (backup → teardown → redeploy → restore) ===
/data/AZUL/scripts/azul-backup.sh start          # 1. Start backup
# ... wait for data to accumulate ...
/data/AZUL/scripts/azul-backup.sh stop           # 2. Stop backup

/data/AZUL/scripts/azul-teardown.sh --force      # 3. Wipe everything

/data/AZUL/scripts/azul-deploy.sh all            # 4. Redeploy (3 stages)
# OR: /data/AZUL/scripts/Infra_install.sh + azul-deploy.sh app + azul-deploy.sh plugins

/data/AZUL/scripts/azul-restore.sh               # 5. Restore from backup
```

### Infra_install.sh Step Reference

```
Step  What                           Key Files/Resources Touched
────  ──────────────────────────     ──────────────────────────────────────
  1   Generate credentials           .azul-credentials (static passwords)
  2   Install Strimzi operator       charts/strimzi...tgz → kafka namespace
  3   Install OpenSearch operator    charts/opensearch...tgz → opensearch-operator namespace
  4   Create namespace + secrets     azul-infra namespace, 4 K8s secrets
  5   Helm install azul-infra        azul-app/infra/ + azul-infra-values.yaml
  6   Patch CA + wait for pods       setup-certs.sh → ca-certificates, wait for Kafka/MinIO/PG/KC
  7   OpenSearch unsafe-bootstrap    Scale down → bootstrap Job → scale up
  8   CoreDNS + Keycloak TLS cert    CoreDNS configmap, cert-manager Certificate
  9   Bake CA into OpenSearch        helm upgrade + unsafe-bootstrap restart
 10   Keycloak setup + verify        setup-keycloak.sh, health checks
```

### Lifecycle Test Results (2026-02-12)

| Step | Result | Details |
|------|--------|---------|
| Backup | PASS | 30MB backed up (2.8MB events, 27MB streams) |
| Teardown | PASS | All 4 namespaces removed, Strimzi + OpenSearch CRDs deleted |
| Validate | PASS | No azul namespaces, no CRDs, no helm releases, MinIO data intact |
| Infra redeploy | PASS | All pods running, Keycloak 200, OpenSearch green |
| Core redeploy | PASS | 13/13 pods, Web UI 302, OAuth OK, API /users/me 200 |
| Plugins redeploy | PASS | 62/63 pods (ghidra Pending — 500m CPU, known limitation) |
| Restore | PASS | 3,318 events + 419 streams restored at 194 events/s |

---

## Container Images Required

### Infrastructure Images (azul-infra namespace)

```
minio/minio:RELEASE.2025-09-07T16-13-09Z
quay.io/keycloak/keycloak:26.1
postgres:17.4
deviceinsight/kafkactl:v5.13.0-ubuntu
docker.io/opensearchproject/opensearch:3.2.0
docker.io/opensearchproject/opensearch-dashboards:3.2.0
docker.io/busybox:latest    # init containers
```

### Kafka Images (managed by Strimzi)

```
quay.io/strimzi/kafka:0.50.0-kafka-4.0.0
quay.io/strimzi/kafka:0.50.0-kafka-4.1.1
```

### Operator Images

```
quay.io/strimzi/operator:0.50.0                          # Strimzi (kafka namespace)
opensearchproject/opensearch-operator:2.8.0               # OpenSearch (opensearch-operator namespace)
gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0                # OpenSearch operator dependency
```

### AZUL App Core Images (azul namespace)

```
docker.io/asdazul/dispatcher:9.0.0
docker.io/asdazul/restapi-server:9.0.0
docker.io/asdazul/webui:9.0.0
docker.io/asdazul/docs:9.0.0
docker.io/asdazul/client:9.0.0
docker.io/asdazul/backup:9.0.0
docker.io/redis:8.4.0-bookworm
```

### AZUL Plugin Images (all from docker.io/asdazul/ with tag 9.0.0)

**Office group** (8 plugins, 1 image): `plugin-office:9.0.0`

**Tika group** (1 plugin + 1 external sidecar):
```
plugin-tika:9.0.0
docker.io/apache/tika:3.2.3.0-full    # External: Apache Tika server sidecar
```

**Generic group** (40 plugins, 18 distinct images):
```
plugin-alphabets, plugin-android-parser, plugin-build-time-strings, plugin-mandiant-capa,
plugin-certificates, plugin-debloat, plugin-de4dot, plugin-dotnet-decompiler, plugin-dotnet-deob,
plugin-email, plugin-entropy, plugin-entrypointcheck, plugin-exiftool, plugin-export-hashes,
plugin-floss, plugin-ghidra, plugin-goinfo, plugin-image-convert, plugin-index-coincidence,
plugin-js-deobf, plugin-lief, plugin-lookback, plugin-malcarve, plugin-netinfo,
plugin-pdftools, plugin-portex, plugin-qrcode, plugin-python, plugin-repeated-bytes,
plugin-richid, plugin-script-decoder, plugin-shortcut, plugin-unbox
```

**Source-based groups** (yara-x, suricata, maco):
```
plugin-yara:9.0.0, plugin-suricata:9.0.0, plugin-maco:9.0.0
registry.k8s.io/git-sync/git-sync:v4.5.0    # External: git-sync sidecar for rule sources
```

### Image Pull Script (for offline pre-staging)

```bash
#!/bin/bash
REGISTRY="docker.io/asdazul"
TAG="9.0.0"

PLUGINS=(
  plugin-office plugin-tika plugin-alphabets plugin-android-parser plugin-build-time-strings
  plugin-mandiant-capa plugin-certificates plugin-debloat plugin-de4dot
  plugin-dotnet-decompiler plugin-dotnet-deob plugin-email plugin-entropy plugin-entrypointcheck
  plugin-exiftool plugin-export-hashes plugin-floss plugin-ghidra plugin-goinfo plugin-image-convert
  plugin-index-coincidence plugin-js-deobf plugin-lief plugin-lookback plugin-malcarve plugin-netinfo
  plugin-pdftools plugin-portex plugin-qrcode plugin-python plugin-repeated-bytes plugin-richid
  plugin-script-decoder plugin-shortcut plugin-unbox plugin-yara plugin-suricata plugin-maco
)

for img in "${PLUGINS[@]}"; do
  echo "Pulling ${REGISTRY}/${img}:${TAG}..."
  docker pull "${REGISTRY}/${img}:${TAG}"
done

echo "Pulling external images..."
docker pull docker.io/apache/tika:3.2.3.0-full
docker pull registry.k8s.io/git-sync/git-sync:v4.5.0
```

---

## Credentials Summary

All credentials saved to `/data/AZUL/.azul-credentials` (mode 600).

| Service | Username | Secret Name | Namespace | Notes |
|---------|----------|-------------|-----------|-------|
| MinIO | (from creds file) | `s3-keys` | azul-infra + azul | Keys: `accesskey`, `secretkey` |
| OpenSearch Admin | admin | `azul-cluster-admincredentials` | azul-infra | |
| OpenSearch Dashboard | kibanaserver | `azul-cluster-dashboardcredentials` | azul-infra | |
| Keycloak Admin | admin | `keycloak` | azul-infra | Key: `KEYCLOAK_ADMIN_PASSWORD` |
| Redis | (empty username) | `redis` | azul | Keys: `redis-username`, `redis-password`, `password` |
| Metastore Writer | azul_writer | `metastore-creds` | azul | Key: `writer` (bcrypt hash in infra values) |
| Backup S3 | azul-backup | `s3-backup-keys` | azul | External MinIO creds (azul-backup-secret) |
| Keycloak Test User | basic | - | - | Password: basic12345 (via setup-keycloak.sh) |
| Keycloak Admin User | azuladmin | - | - | Password: admin12345 (via setup-keycloak.sh) |
| OpenSearch Dashboards OIDC | opensearch-dashboards | - | - | Client secret: `opensearch-dashboards-secret` |

---

## Issues & Changes Log

| # | Issue | Resolution | Status |
|---|-------|------------|--------|
| 1 | Strimzi `watchNamespaces="{*}"` YAML parse error | Used `watchAnyNamespace=true` instead | FIXED |
| 2 | Keycloak ingress backend port was `80`, should be `8080` | Edited template `keycloak.yaml` (Patch 1) | FIXED |
| 3 | Kafka template `group` field not a valid Strimzi resource group | Added `name` field alongside `group` in kafkactl deployment | FIXED |
| 4 | OpenSearch dashboard `multiple_auth_enabled` not propagated | Operator reconciled from CRD additionalConfig | FIXED |
| 5 | Pods can't resolve `*.kp.local` DNS inside cluster | Added `hosts` block to CoreDNS Corefile | FIXED |
| 6 | Dashboard OIDC: `DEPTH_ZERO_SELF_SIGNED_CERT` | Created cert-manager Certificate for keycloak-tls; mounted CA via additionalVolumes + NODE_EXTRA_CA_CERTS | FIXED |
| 7 | Dashboard template missing `additionalVolumes` support | Added template block to opensearch.yaml (Patch 2) | FIXED |
| 8 | OpenSearch template missing `general.additionalConfig` support | Added template block to opensearch.yaml (Patch 3) | FIXED |
| 9 | Single-node OpenSearch: `cluster_manager_not_discovered_exception` | Used `opensearch-node unsafe-bootstrap` to reset voting config | FIXED |
| 10 | `discovery.type: single-node` conflicts with `cluster.initial_master_nodes` | Removed discovery.type; used unsafe-bootstrap instead | FIXED |
| 11 | OpenSearch `AccessDeniedException` on data dir | Delete pod to trigger fresh init containers with chown | FIXED |
| 12 | securityadmin timeout (`H2StreamResetException`) | Root cause: no data nodes (cluster RED); resolved when data node started | FIXED |
| 13 | App chart 10.0.0-unstable images not on Docker Hub | Switched to stable `azul-9.0.0` git tag | FIXED |
| 14 | 9.0.0 chart schema rejects extra values | Removed `consumerGroupRetentionDays`, `origin_alt_name`, `azulReportFeeds` | FIXED |
| 15 | CORS values with JSON brackets break YAML template | Changed to defaults: `"[]"` | FIXED |
| 16 | Keycloak 26.x JWT missing `sub` claim | Added `oidc-sub-mapper` to azul client scope in setup-keycloak.sh | FIXED |
| 17 | OpenSearch OIDC 401 — can't validate Keycloak JWT | Test CA not in Mozilla CA bundle; patched into chart's ca-certificates file via setup-certs.sh | FIXED |
| 18 | CPU request exhaustion with 60+ pods | Reduced LimitRange default CPU from 50m to 10m; scale-to-zero/one workaround | FIXED |
| 19 | YARA-X incompatible with public YARA rules repo | Removed source; yara-x enabled with empty sources | FIXED |
| 20 | Tika 2-container pod unschedulable — CPU request=limits | Added explicit 10m CPU requests alongside limits | FIXED |
| 21 | Backup pod Pending — 250m CPU / 2Gi memory too high | Reduced to 10m CPU / 512Mi memory requests | FIXED |
| 22 | Redis secret missing `redis-username` key | Chart expects `redis-username`, `redis-password`, AND `password`; recreated secret | FIXED |
| 23 | Helm configmap field manager conflict after manual CA append | Used `--server-side --field-manager=helm --force-conflicts`; later eliminated by baking CA into chart file | FIXED |
| 24 | Pi-hole missing Azul DNS records | Added all 5 `*.kp.local` Azul hostnames to Pi-hole | FIXED |
| 25 | `azul-web-tls` cert missing — nginx serving Fake Certificate | Created cert-manager Certificate via setup-certs.sh (copies CA + Issuer to azul namespace) | FIXED |
| 26 | OIDC scopes wrong — missing `offline_access` and `roles` | Changed to `openid profile offline_access roles azul` in values + helm upgrade | FIXED |
| 27 | `grep -c` exit code 1 when count=0 breaks conditionals | Use `var=$(...) \|\| var="0"` pattern, not `$(...\|\| echo "0")` | FIXED |
| 28 | OpenSearch node ID changes on pod restart | Always run unsafe-bootstrap (scale down → job → scale up) instead of simple pod delete | FIXED |
| 29 | Stale `opensearch-ca.crt` file from previous deploy | Eliminated; CA now extracted from cluster secret at runtime by setup-certs.sh | FIXED |
| 30 | Plugin deployment name pattern mismatch | Simplified to `grep -E "^plugin-"` | FIXED |
| 31 | Restore job status check infinite loop | K8s Job conditions: iterate all with `{range .status.conditions[*]}` not just [0] | FIXED |
| 32 | Keycloak `roles` scope not assigned to azul-web client | Added explicit PUT to assign `roles` as optional scope in setup-keycloak.sh | FIXED |
| 33 | Keycloak `audience` scope missing audience mapper | Added `oidc-audience-mapper` with `included.client.audience: azul-web` | FIXED |
| 34 | `helm upgrade azul-infra` strips Test CA from configmap | Baked Test CA into chart's `ca-certificates` file via setup-certs.sh; all future helm upgrades preserve it | FIXED |

---

## Known Gotchas

1. **Writer password sync**: When creating a fresh `metastore-creds` secret, the bcrypt hash in `azul-infra-values.yaml` must be updated and `helm upgrade azul-infra` must be run. The deploy script handles this automatically.

2. **OpenSearch unsafe-bootstrap after every restart**: Single-node OpenSearch requires unsafe-bootstrap after EVERY pod restart (not just initial deploy). The node ID changes each time, invalidating the voting config. The deploy script's `run_opensearch_bootstrap` handles this.

3. **Keycloak setup-keycloak.sh timeout**: The script uses `kubectl port-forward` which may time out. If it doesn't complete all steps, manually finish via the Keycloak Admin Console.

4. **Ghidra CPU**: The ghidra plugin requests 500m CPU which may not be available on a fully packed cluster. It will show as Pending — acceptable, it schedules when resources become available.

5. **Metastore initial CrashLoop**: On first deploy, metastore pods CrashLoop 2-3 times while dispatchers initialise Kafka topic connections. Self-resolves within ~2 minutes.

6. **Web TLS certificate**: The `azul-web-tls` secret must be created manually (or by setup-certs.sh / deploy script). The Helm chart references it but doesn't create it. Without it, nginx serves a fake certificate.

7. **Pi-hole DNS records**: All `*.kp.local` Azul hostnames must be in Pi-hole. The browser OIDC flow redirects to `keycloak-azul.kp.local` — if DNS doesn't resolve, login fails silently.

8. **OIDC scopes must be exact**: For Keycloak, use `openid profile offline_access roles azul`. Without `offline_access`, sessions can't refresh tokens. Without `roles`, role-based access won't work.

9. **Keycloak audience mapper required**: The `audience` client scope must include an `oidc-audience-mapper` with `included.client.audience: azul-web`. Without it, access tokens have `aud: "account"` and the REST API rejects them.

10. **Keycloak 26.x sub claim**: Keycloak 26.x does not include the `sub` claim in JWTs by default. The `oidc-sub-mapper` in the `azul` client scope fixes this. Without it, the restapi rejects tokens with "JWT does not have a subject".

11. **Redis secret needs 3 keys**: The chart expects `redis-username`, `redis-password`, AND `password`. Missing any key causes `CreateContainerConfigError` on dispatcher pods.

12. **Backup pod resources**: Must be low (10m CPU / 512Mi memory requests) or it stays Pending on a packed cluster. Already configured in the values files.

---

## Homelab Adaptations

| Setting | Production Default | Homelab Value | Reason |
|---------|-------------------|---------------|--------|
| MinIO replicas | 3 | 1 | local-path storage, single node sufficient |
| MinIO backup | Enabled (3 replicas) | Disabled | External MinIO used instead |
| Kafka replicas | 3 | 1 | Resource savings |
| Kafka replication.factor | 3 | 1 | Single broker |
| Kafka min.insync.replicas | 2 | 1 | Single broker |
| OpenSearch replicas | 3 | 1 | Resource savings |
| Storage class | managed-csi | local-path | Homelab provisioner |
| Monitoring stack | Enabled | Disabled | Resource savings |
| Ingress class | default | nginx | Homelab nginx ingress |
| MinIO storage | 50Gi | 10Gi | Homelab sizing |
| Kafka storage | 100Gi | 20Gi | Homelab sizing |
| OpenSearch storage | 50Gi | 20Gi | Homelab sizing |
| LimitRange CPU | 50m | 10m | 60+ pods on 4 workers |

---

## Offline Install Checklist

### Pre-staging (with internet)

1. [ ] Clone this repo: `git clone https://github.com/PeeBee66/AZUL-setup.git /data/AZUL`
   - Includes: azul-app charts (pre-patched), operator .tgz files, all scripts, values files
2. [ ] Create `.azul-credentials` file with generated passwords (see [Prerequisites](#prerequisites))
3. [ ] Pull all container images (see [Container Images Required](#container-images-required) and image pull script)
4. [ ] Transfer `/data/AZUL/` directory and container images to offline media

### Installation (offline)

7. [ ] Load all container images into target registry or nodes
8. [ ] Configure Pi-hole DNS records (see [DNS Records](#dns-records))
9. [ ] Apply Talos PodSecurity exemptions (see [Prerequisites](#prerequisites))
10. [ ] Install using deploy script or manual steps:
    - **Scripted**: `/data/AZUL/scripts/azul-deploy.sh all`
    - **Manual**: Follow [Step-by-Step Manual Install](#step-by-step-manual-install)

### Verification

11. [ ] `kubectl get pods -n azul-infra` — all infra pods Running
12. [ ] `kubectl get pods -n azul` — 63 pods Running (13 core + 50 plugins)
13. [ ] Web UI loads at `https://azul.kp.local/`
14. [ ] Login works with test user (`basic / basic12345`)
15. [ ] Submit a test file — plugin results should appear within ~1 minute

---

## Script Reference

All scripts work on **Ubuntu 22.04+** and **RHEL 9+**. They use bash, kubectl, helm, curl, python3 (no jq/yq required). All scripts send Discord notifications on success/failure.

| Script | Purpose | Usage |
|--------|---------|-------|
| `Infra_install.sh` | Standalone infra install with image/registry reference | `./Infra_install.sh [--step N] [--check] [--creds]` |
| `azul-deploy.sh` | 3-stage deploy with health checks | `./azul-deploy.sh {all\|infra\|app\|plugins}` |
| `azul-teardown.sh` | Complete Azul removal | `./azul-teardown.sh [--force]` |
| `azul-backup.sh` | Continuous backup to external MinIO | `./azul-backup.sh [start\|stop\|status]` |
| `azul-restore.sh` | Restore from backup | `./azul-restore.sh [--check] [--label ID]` |
| `setup-certs.sh` | Certificate management | `./setup-certs.sh {all\|patch-ca\|keycloak\|azul}` |
| `setup-keycloak.sh` | Keycloak realm/client/user setup | `bash setup-keycloak.sh` |
