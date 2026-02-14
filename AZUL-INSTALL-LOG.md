# AZUL Installation Log - Homelab (KUBS Cluster)

**Date**: 2026-02-11
**Cluster**: KUBS (5-node Talos Linux K8s v1.34.3 on Proxmox)
**Source Repo**: https://github.com/AustralianCyberSecurityCentre/azul-app (cloned to /data/AZUL/azul-app)
**Source Docs**: https://australiancybersecuritycentre.github.io/azul/developer-guide/components/core/app/
**AZUL Version**: 10.0.0-unstable (infra chart), 9.0.0 (app chart)
**Purpose**: Online install with full documentation for future offline replication

---

## Overview

AZUL is a malware repository, analytical engine, and clustering suite by the Australian Cyber Security Centre (ACSC/ASD). It runs on Kubernetes with:
- **Kafka** (event store via Strimzi operator)
- **OpenSearch** (search/indexing via OpenSearch K8s operator)
- **MinIO** (S3-compatible object storage)
- **Keycloak** (OIDC authentication)
- **Redis** (in-memory cache, bundled in app chart)

## 3-Stage Installation Process

1. **AZUL-Infra**: Operators + Infrastructure components (Kafka, OpenSearch, MinIO, Keycloak) - **COMPLETED**
2. **Azul**: Main application (dispatcher, restapi, webui, metastore, redis) - **COMPLETED**
3. **Plugins**: Analysis plugins (office, tika, generic, YARA-X, suricata, MACO) - **COMPLETED**

---

## Homelab Adaptations (vs Production Defaults)

| Setting | Production Default | Homelab Value | Reason |
|---------|-------------------|---------------|--------|
| MinIO replicas | 3 | 1 | local-path storage, single node sufficient |
| MinIO backup | Enabled (3 replicas) | Disabled | Not needed for homelab |
| Kafka replicas | 3 | 1 | Resource savings, single node |
| Kafka replication.factor | 3 | 1 | Single broker |
| Kafka min.insync.replicas | 2 | 1 | Single broker |
| OpenSearch replicas | 3 | 1 | Resource savings |
| Storage class | managed-csi | local-path | Homelab provisioner |
| Monitoring stack | Enabled | Disabled | Resource savings, already have alternatives |
| Ingress class | default | nginx | Homelab nginx ingress |
| MinIO storage | 50Gi | 10Gi | Homelab sizing |
| Kafka storage | 100Gi | 20Gi | Homelab sizing |
| OpenSearch storage | 50Gi | 20Gi | Homelab sizing |

---

## Stage 1: AZUL-Infra

### 1.1 Prerequisites Installed

- [x] Kubernetes v1.34.3 (Talos Linux)
- [x] cert-manager v1.16.2 (already installed)
- [x] nginx ingress controller (already installed as DaemonSet)
- [x] Strimzi Kafka Operator (v0.50.0)
- [x] OpenSearch Kubernetes Operator (v2.8.0)
- [x] Talos PodSecurity exemptions updated (added: kafka, opensearch-operator, azul-infra, azul)

### 1.2 Strimzi Kafka Operator Installation

**Status**: COMPLETED

```bash
helm repo add strimzi https://strimzi.io/charts/
helm install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace kafka --create-namespace \
  --set watchAnyNamespace=true \
  --version 0.50.0
```

**Note**: Initial attempt with `--set watchNamespaces="{*}"` failed with YAML parse error.
Used `--set watchAnyNamespace=true` instead - this is the correct parameter.

**Offline files needed**:
- Strimzi Helm chart: `helm pull strimzi/strimzi-kafka-operator --version 0.50.0`
- Images: `quay.io/strimzi/operator:0.50.0`, `quay.io/strimzi/kafka:0.50.0-kafka-4.0.0`, `quay.io/strimzi/kafka:0.50.0-kafka-4.1.1`

### 1.3 OpenSearch Operator Installation

**Status**: COMPLETED

```bash
helm repo add opensearch-operator https://opensearch-project.github.io/opensearch-k8s-operator/
helm install opensearch-operator opensearch-operator/opensearch-operator \
  --namespace opensearch-operator --create-namespace \
  --version 2.8.0
```

**Offline files needed**:
- OpenSearch Operator chart: `helm pull opensearch-operator/opensearch-operator --version 2.8.0`
- Images: `opensearchproject/opensearch-operator:2.8.0`, `gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0`

### 1.3.1 Talos PodSecurity Exemptions Update

**Status**: COMPLETED

Added namespaces via JSON patch: `kafka`, `opensearch-operator`, `azul-infra`, `azul`

```bash
talosctl --talosconfig /home/kp-admin/KUBS/talosconfig -n 192.168.66.201 patch mc --patch '[{"op":"replace","path":"/cluster/apiServer/admissionControl","value":[{"name":"PodSecurity","configuration":{"apiVersion":"pod-security.admission.config.k8s.io/v1alpha1","kind":"PodSecurityConfiguration","defaults":{"enforce":"baseline","enforce-version":"latest","audit":"restricted","audit-version":"latest","warn":"restricted","warn-version":"latest"},"exemptions":{"namespaces":["kube-system","ingress-nginx","unifi","home-assistant","local-path-storage","keel","headlamp","homarr","teslamate","kafka","opensearch-operator","azul-infra","azul"],"runtimeClasses":[],"usernames":[]}}}]}]'
```

### 1.4 Namespace & Secrets Creation

**Status**: COMPLETED

**Namespace**: `azul-infra` (created by helm install with `--create-namespace`)

**Secrets created manually before helm install**:

```bash
# Create namespace first
kubectl create namespace azul-infra

# MinIO access keys
kubectl create secret generic s3-keys -n azul-infra \
  --from-literal=accesskey=minioadmin \
  --from-literal=secretkey=minioadmin

# OpenSearch admin credentials (operator auto-generates if not present)
kubectl create secret generic azul-cluster-admincredentials -n azul-infra \
  --from-literal=username=admin \
  --from-literal=password="$(openssl rand -base64 24)"

# OpenSearch dashboard credentials
kubectl create secret generic azul-cluster-dashboardcredentials -n azul-infra \
  --from-literal=username=kibanaserver \
  --from-literal=password="$(openssl rand -base64 24)"

# Keycloak secrets
kubectl create secret generic keycloak -n azul-infra \
  --from-literal=DB_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="$(openssl rand -base64 24)"
```

**Credentials saved to**: `/data/AZUL/.azul-credentials` (mode 600)

### 1.5 Infra Helm Chart Deployment

**Status**: COMPLETED (revision 8)

**Release Name**: azul-infra
**Chart**: /data/AZUL/azul-app/infra
**Namespace**: azul-infra
**Custom Values**: /data/AZUL/azul-infra-values.yaml

```bash
helm install azul-infra /data/AZUL/azul-app/infra \
  -n azul-infra \
  -f /data/AZUL/azul-infra-values.yaml
```

**Upgrade command** (after values changes):
```bash
helm upgrade azul-infra /data/AZUL/azul-app/infra \
  -n azul-infra \
  -f /data/AZUL/azul-infra-values.yaml
```

### 1.6 Helm Template Changes Required

The upstream infra chart templates needed modifications for our setup. These changes must be replicated if re-cloning the repo.

#### 1.6.1 Keycloak Ingress Port Fix

**File**: `/data/AZUL/azul-app/infra/templates/keycloak/keycloak.yaml`
**Issue**: Ingress backend port was `80`, but Keycloak service uses port `8080`
**Fix**: Changed `number: 80` to `number: 8080` at the ingress backend service port.

#### 1.6.2 OpenSearch Dashboard additionalVolumes Support

**File**: `/data/AZUL/azul-app/infra/templates/opensearch.yaml`
**Issue**: The template didn't pass `dashboard.additionalVolumes` to the OpenSearchCluster CRD.
**Fix**: Added after the `env` block (around line 258):
```yaml
{{- if .Values.opensearch.dashboard.additionalVolumes }}
    additionalVolumes:
{{ .Values.opensearch.dashboard.additionalVolumes | toYaml | nindent 6 }}
{{- end }}
```

#### 1.6.3 OpenSearch General additionalConfig Support

**File**: `/data/AZUL/azul-app/infra/templates/opensearch.yaml`
**Issue**: The template didn't pass `general.additionalConfig` to the CRD.
**Fix**: Added after `setVMMaxMapCount` (around line 175):
```yaml
{{- if .Values.opensearch.general.additionalConfig }}
    additionalConfig:
{{ .Values.opensearch.general.additionalConfig | toYaml | nindent 6 }}
{{- end }}
```

### 1.7 Post-Infra Configuration

#### 1.7.1 CoreDNS Configuration

**Status**: COMPLETED

Pods inside the cluster can't resolve `*.kp.local` domains because CoreDNS forwards to upstream DNS which doesn't know about them. Added static `hosts` entries.

```bash
kubectl edit configmap coredns -n kube-system
```

Added the following `hosts` block inside the Corefile, before the `forward` directive:

```
hosts {
    192.168.66.201 keycloak-azul.kp.local
    192.168.66.201 opensearch-azul.kp.local
    192.168.66.201 azul.kp.local
    fallthrough
}
```

Then restarted CoreDNS:
```bash
kubectl rollout restart deployment coredns -n kube-system
```

#### 1.7.2 OpenSearch CA Certificate Extraction

**Status**: COMPLETED

```bash
kubectl get secret azul-opensearch-ca-cert -n azul-infra \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /data/AZUL/opensearch-ca.crt
```

#### 1.7.3 Keycloak TLS Certificate (via cert-manager)

**Status**: COMPLETED

The Keycloak ingress needed a proper TLS certificate signed by the same CA that OpenSearch trusts (for OIDC communication between OpenSearch Dashboards and Keycloak inside the cluster).

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
```

#### 1.7.4 Keycloak Realm & User Configuration

**Status**: COMPLETED

Script: `/data/AZUL/setup-keycloak.sh`

Configured:
- **Realm**: `azul` (enabled, accessTokenLifespan=300, ssoSessionMaxLifespan=36000)
- **Realm Roles**: azul-access, azul_read, azul_admin, azul_write, s-any, s-official
- **Groups**: general, opensearch-admins
- **Client Scope "azul"**: With realm-roles mapper (claims roles in id/access/userinfo tokens)
- **Client Scope "audience"**: For audience mapping
- **Client "azul-web"**: Public client for Web UI (redirects to https://azul.kp.local/*)
- **Client "opensearch-dashboards"**: Confidential client (secret: `opensearch-dashboards-secret`)
- **Client "azul-service"**: Service account client for API
- **Test User**: `basic` / `basic12345` (all azul roles, general group)
- **Admin User**: `azuladmin` / `admin12345` (all azul roles, opensearch-admins group)

```bash
bash /data/AZUL/setup-keycloak.sh
```

#### 1.7.5 OpenSearch Single-Node Bootstrap Fix (CRITICAL)

**Status**: COMPLETED

**Problem**: The OpenSearch Kubernetes Operator uses a bootstrap process that creates a temporary `bootstrap-0` pod for initial cluster formation. After security is initialized, the operator removes the bootstrap pod. For single-node clusters (1 replica), this breaks the voting configuration - the remaining data node loses quorum because the voting config still references the removed bootstrap node, causing `cluster_manager_not_discovered_exception`.

**Symptoms**:
- `cluster_manager_not_discovered_exception` errors on the data node
- Data node shows 0/1 Ready
- Cluster health returns 503

**Solution**: After the operator completes bootstrap and removes the bootstrap pod, use OpenSearch's `unsafe-bootstrap` tool to reset the voting configuration:

```bash
# 1. Scale down the operator to prevent interference
kubectl scale deployment opensearch-operator-controller-manager \
  -n opensearch-operator --replicas=0

# 2. Scale down the data node StatefulSet
kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=0

# 3. Wait for pod to terminate
sleep 15

# 4. Run unsafe-bootstrap via a temporary Job
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
        command:
        - /bin/bash
        - -c
        - |
          echo "y" | /usr/share/opensearch/bin/opensearch-node unsafe-bootstrap
        volumeMounts:
        - name: data
          mountPath: /usr/share/opensearch/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: data-azul-opensearch-nodes-0
EOF

# 5. Wait for Job to complete
kubectl wait --for=condition=complete job/opensearch-unsafe-bootstrap \
  -n azul-infra --timeout=120s

# 6. Clean up and restore
kubectl delete job opensearch-unsafe-bootstrap -n azul-infra
kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=1
kubectl scale deployment opensearch-operator-controller-manager \
  -n opensearch-operator --replicas=1
```

**Note**: This is only needed for single-replica OpenSearch clusters. With 3+ replicas, the operator's bootstrap removal doesn't break quorum.

#### 1.7.6 Keycloak JWT Subject Claim Fix (CRITICAL)

**Status**: COMPLETED

**Problem**: Keycloak 26.x does not include the `sub` (subject) claim in JWTs by default. The Azul restapi validates every JWT and rejects tokens without `sub`, returning 401 "JWT does not have a subject and is therefore invalid."

**Root cause**: The Keycloak realm was created without a built-in `openid` client scope (which normally provides the `sub` mapper). The `setup-keycloak.sh` script specified `openid` in client `defaultClientScopes`, but since no scope with that name existed in the realm, it was silently ignored.

**Solution**: Add an `oidc-sub-mapper` protocol mapper to the `azul` client scope (which IS assigned to all clients):

```bash
# Via Keycloak Admin API (already added to setup-keycloak.sh):
curl -X POST "${KC_URL}/admin/realms/azul/client-scopes/${AZUL_SCOPE_ID}/protocol-mappers/models" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"name":"subject","protocol":"openid-connect","protocolMapper":"oidc-sub-mapper","config":{"id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}'
```

**Verification**: Decode a user's access token and confirm `"sub": "<uuid>"` is present.

#### 1.7.7 OpenSearch CA Trust for Keycloak OIDC (CRITICAL)

**Status**: COMPLETED

**Problem**: After fixing the JWT `sub` claim, the restapi could authenticate users via Keycloak, but when it forwarded the JWT to OpenSearch, OpenSearch returned 401 "Authentication finally failed". OpenSearch logs showed: `unable to find valid certification path to requested target` when trying to fetch Keycloak's JWKS endpoint.

**Root cause**: The `azul-opensearch-certs` configmap contains a Mozilla CA bundle (public CAs) at the `ca-certificates` key. OpenSearch's OIDC config references this file via `pemtrustedcas_filepath`. But the Keycloak ingress TLS cert is signed by the self-signed `Test CA` (created by cert-manager using the OpenSearch CA issuer), which is NOT in the Mozilla bundle.

**Solution**: After the Keycloak TLS cert is created (section 1.7.3), append the Test CA to the configmap and restart OpenSearch:

```bash
# 1. Extract the Test CA cert
kubectl get secret azul-opensearch-ca-cert -n azul-infra \
  -o "jsonpath={.data.tls\.crt}" | base64 -d > /tmp/test-ca.pem

# 2. Dump current CA bundle from configmap
kubectl get configmap azul-opensearch-certs -n azul-infra \
  -o "jsonpath={.data.ca-certificates}" > /tmp/os-ca-bundle.pem

# 3. Append the Test CA
echo "" >> /tmp/os-ca-bundle.pem
echo "# Homelab Test CA (signs Keycloak TLS cert)" >> /tmp/os-ca-bundle.pem
cat /tmp/test-ca.pem >> /tmp/os-ca-bundle.pem

# 4. Update the configmap (use server-side apply to avoid field manager conflicts — Issue #23)
kubectl create configmap azul-opensearch-certs -n azul-infra \
  --from-file=ca-certificates=/tmp/os-ca-bundle.pem \
  --dry-run=client -o yaml | kubectl apply --server-side --field-manager=helm --force-conflicts -f -

# 5. Restart OpenSearch to pick up the new CA bundle
kubectl delete pod azul-opensearch-nodes-0 -n azul-infra
kubectl wait --for=condition=Ready pod/azul-opensearch-nodes-0 -n azul-infra --timeout=180s
```

**Note**: This must be re-applied after every `helm upgrade azul-infra` because the configmap is regenerated from the chart's bundled `ca-certificates` file. Use `--server-side --field-manager=helm --force-conflicts` to avoid field manager conflicts on subsequent helm upgrades (Issue #23). Consider adding the Test CA PEM to the chart's `ca-certificates` file for a permanent fix.

**Verification**: `kubectl exec -n azul-infra azul-opensearch-nodes-0 -- grep "Test CA" /usr/share/opensearch/config/certs/ca-certificates`

---

## Current Infrastructure Status

### Running Pods (azul-infra namespace)

| Pod | Ready | Component |
|-----|-------|-----------|
| azul-kafka-nodes-0 | 1/1 | Kafka broker (KRaft mode) |
| azul-kafka-entity-operator-* | 2/2 | Strimzi entity operator |
| azul-kafka-kafka-exporter-* | 1/1 | Kafka metrics exporter |
| azul-kafka-kafkactl-* | 1/1 | Kafka CLI tool |
| azul-opensearch-nodes-0 | 1/1 | OpenSearch data+cluster_manager node |
| azul-opensearch-dashboards-* | 1/1 | OpenSearch Dashboards (with OIDC) |
| keycloak-* (x2) | 1/1 | Keycloak HA (2 replicas) |
| postgres-* | 1/1 | PostgreSQL (for Keycloak) |
| s3-store-minio-0 | 1/1 | MinIO object storage |

### Cluster Health

| Component | Status | Details |
|-----------|--------|---------|
| Kafka | Ready | KRaft mode, 1 broker, Strimzi managed |
| OpenSearch | GREEN | 1 node, 4 active shards, 100% active, security initialized |
| MinIO | Healthy | Single instance, API + Console accessible |
| Keycloak | Running | 2 replicas, HA via JGroups, PostgreSQL backend |
| OpenSearch Dashboards | Running | Connected to OpenSearch, OIDC configured |

### Ingress Endpoints

| URL | Service | Status |
|-----|---------|--------|
| https://opensearch-azul.kp.local | OpenSearch Dashboards | 200 (login page) |
| https://keycloak-azul.kp.local | Keycloak | 200 (realm page) |
| https://minio-azul.kp.local | MinIO Console | Available |
| https://minio-api-azul.kp.local | MinIO API | Available |

### OIDC Integration

- **OpenSearch Dashboards** → **Keycloak** OIDC integration: CONFIGURED
- Auth types: basicauth + openid (multiple auth enabled)
- OIDC Discovery URL: `https://keycloak-azul.kp.local/realms/azul/.well-known/openid-configuration`
- Client: `opensearch-dashboards` (confidential, secret: `opensearch-dashboards-secret`)
- Dashboards CA trust: OpenSearch self-signed CA mounted via `NODE_EXTRA_CA_CERTS`
- OpenSearch backend OIDC: Configured in securityConfig with Keycloak OIDC auth domain

---

## DNS Records Needed (Pi-hole)

| Hostname | IP | Purpose |
|----------|-----|---------|
| azul.kp.local | 192.168.66.201 | AZUL Web UI |
| keycloak-azul.kp.local | 192.168.66.201 | Keycloak auth |
| opensearch-azul.kp.local | 192.168.66.201 | OpenSearch Dashboards |
| minio-azul.kp.local | 192.168.66.201 | MinIO Console |
| minio-api-azul.kp.local | 192.168.66.201 | MinIO API |

**Also**: CoreDNS must have hosts entries for `keycloak-azul.kp.local`, `opensearch-azul.kp.local`, and `azul.kp.local` pointing to `192.168.66.201` (see section 1.7.1).

---

## Container Images Required (for Offline Install)

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

### Kafka Images (managed by Strimzi, azul-infra namespace)
```
quay.io/strimzi/kafka:0.50.0-kafka-4.0.0
quay.io/strimzi/kafka:0.50.0-kafka-4.1.1
```

### Operator Images
```
# Strimzi (kafka namespace)
quay.io/strimzi/operator:0.50.0

# OpenSearch Operator (opensearch-operator namespace)
opensearchproject/opensearch-operator:2.8.0
gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0
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

### AZUL Plugin Images (azul namespace, all from docker.io/asdazul/ with tag 9.0.0)

**Office group** (8 plugins, 1 image):
```
docker.io/asdazul/plugin-office:9.0.0
```

**Tika group** (1 plugin + 1 external sidecar):
```
docker.io/asdazul/plugin-tika:9.0.0
docker.io/apache/tika:3.2.3.0-full          # External: Apache Tika server sidecar
```

**Generic group** (40 plugins, 18 distinct images):
```
docker.io/asdazul/plugin-alphabets:9.0.0
docker.io/asdazul/plugin-android-parser:9.0.0
docker.io/asdazul/plugin-build-time-strings:9.0.0
docker.io/asdazul/plugin-mandiant-capa:9.0.0
docker.io/asdazul/plugin-certificates:9.0.0
docker.io/asdazul/plugin-debloat:9.0.0
docker.io/asdazul/plugin-de4dot:9.0.0
docker.io/asdazul/plugin-dotnet-decompiler:9.0.0
docker.io/asdazul/plugin-dotnet-deob:9.0.0
docker.io/asdazul/plugin-email:9.0.0        # Used by: email-headers, email-mimedecoder, email-olemail
docker.io/asdazul/plugin-entropy:9.0.0
docker.io/asdazul/plugin-entrypointcheck:9.0.0
docker.io/asdazul/plugin-exiftool:9.0.0
docker.io/asdazul/plugin-export-hashes:9.0.0
docker.io/asdazul/plugin-floss:9.0.0
docker.io/asdazul/plugin-ghidra:9.0.0
docker.io/asdazul/plugin-goinfo:9.0.0
docker.io/asdazul/plugin-image-convert:9.0.0
docker.io/asdazul/plugin-index-coincidence:9.0.0
docker.io/asdazul/plugin-js-deobf:9.0.0
docker.io/asdazul/plugin-lief:9.0.0         # Used by: lief-elf, lief-fatmacho, lief-macho, lief-pe
docker.io/asdazul/plugin-lookback:9.0.0     # Used by: lookback-hash, lookback-search
docker.io/asdazul/plugin-malcarve:9.0.0
docker.io/asdazul/plugin-netinfo:9.0.0
docker.io/asdazul/plugin-pdftools:9.0.0     # Used by: pdftools-pdfid, pdftools-pdfinfo, pdftools-pdftext
docker.io/asdazul/plugin-portex:9.0.0
docker.io/asdazul/plugin-qrcode:9.0.0
docker.io/asdazul/plugin-python:9.0.0
docker.io/asdazul/plugin-repeated-bytes:9.0.0
docker.io/asdazul/plugin-richid:9.0.0
docker.io/asdazul/plugin-script-decoder:9.0.0
docker.io/asdazul/plugin-shortcut:9.0.0
docker.io/asdazul/plugin-unbox:9.0.0
```

**Source-based groups** (yara-x, suricata, maco — no pods yet, but images needed if sources added):
```
docker.io/asdazul/plugin-yara:9.0.0         # YARA-X plugin
docker.io/asdazul/plugin-suricata:9.0.0     # Suricata plugin
docker.io/asdazul/plugin-maco:9.0.0         # MACO extractor plugin
registry.k8s.io/git-sync/git-sync:v4.5.0    # External: git-sync sidecar for rule sources
```

### Image Pull Script (for offline pre-staging)

```bash
#!/bin/bash
# Pull all AZUL plugin images for offline install
# Run on a machine with internet access, then transfer to air-gapped registry

REGISTRY="docker.io/asdazul"
TAG="9.0.0"

# Plugin images (34 distinct images)
PLUGINS=(
  plugin-office plugin-tika
  plugin-alphabets plugin-android-parser plugin-build-time-strings
  plugin-mandiant-capa plugin-certificates plugin-debloat plugin-de4dot
  plugin-dotnet-decompiler plugin-dotnet-deob plugin-email
  plugin-entropy plugin-entrypointcheck plugin-exiftool plugin-export-hashes
  plugin-floss plugin-ghidra plugin-goinfo plugin-image-convert
  plugin-index-coincidence plugin-js-deobf plugin-lief plugin-lookback
  plugin-malcarve plugin-netinfo plugin-pdftools plugin-portex
  plugin-qrcode plugin-python plugin-repeated-bytes plugin-richid
  plugin-script-decoder plugin-shortcut plugin-unbox
  plugin-yara plugin-suricata plugin-maco
)

for img in "${PLUGINS[@]}"; do
  echo "Pulling ${REGISTRY}/${img}:${TAG}..."
  docker pull "${REGISTRY}/${img}:${TAG}"
done

# External images
echo "Pulling external images..."
docker pull docker.io/apache/tika:3.2.3.0-full
docker pull registry.k8s.io/git-sync/git-sync:v4.5.0
```

---

## Files Needed for Offline Install

### From GitHub Repository
```
azul-app/                          # Full repo clone
├── azul/                          # Main app Helm chart
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── example-values.yaml
│   ├── values.schema.json
│   ├── templates/
│   └── monitoring/
├── infra/                         # Infrastructure Helm chart
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── ca-certificates
│   ├── charts/                    # Bundled dependencies
│   │   ├── kube-prometheus-stack-77.12.0.tgz
│   │   ├── loki-6.41.1.tgz
│   │   ├── prometheus-blackbox-exporter-11.3.1.tgz
│   │   └── prometheus-pushgateway-3.4.1.tgz
│   ├── templates/
│   └── scripts/
└── cosign.pub                     # Image signature verification
```

### Custom Configuration Files (created during install)
```
/data/AZUL/azul-infra-values.yaml       # Infra chart overrides (main config)
/data/AZUL/azul-values.yaml             # App chart overrides - Stage 3 (core + all plugins)
/data/AZUL/azul-values-core.yaml        # App chart overrides - Stage 2 (core only, no plugins)
/data/AZUL/.azul-credentials            # Kubernetes secrets (SENSITIVE, mode 600)
/data/AZUL/setup-keycloak.sh            # Keycloak configuration script
/data/AZUL/opensearch-ca.crt            # OpenSearch CA certificate (extracted)
/data/AZUL/docker-compose-backup.yaml   # External MinIO for backup (docker/podman)
/data/AZUL/scripts/azul-backup.sh       # Backup to external MinIO
/data/AZUL/scripts/azul-teardown.sh     # Complete Azul removal from cluster
/data/AZUL/scripts/azul-deploy.sh       # 3-stage deploy (infra → app → plugins)
/data/AZUL/scripts/azul-restore.sh      # Restore from external MinIO backup
```

**Key changes in `azul-values.yaml` for plugins** (vs initial no-plugins install):
- `pluginsEnabled: true` (was `false`)
- `limitRange.spec.limits[0].defaultRequest.cpu: 10m` (was `50m`, reduced for 60+ pod density)
- `plugins.office.enabled: true` with 8 sub-plugins defined
- `plugins.tika.enabled: true` with explicit low CPU requests on both containers
- `plugins.generic.enabled: true` with all 40 sub-plugins; heavy ones have reduced memory
- `plugins.yara-x.enabled: true` with empty sources (YARA-X incompatible with classic YARA repos)
- `plugins.suricata.enabled: true` with empty sources
- `plugins.maco.enabled: true` with empty sources
- `plugins.nsrl.server.enabled: false` (must explicitly disable to prevent NSRL server pod when `pluginsEnabled: true`)

### Operator Helm Charts (for offline)
```bash
# Download for offline use:
helm pull strimzi/strimzi-kafka-operator --version 0.50.0
helm pull opensearch-operator/opensearch-operator --version 2.8.0
```

---

## Issues & Changes Log

| # | Issue | Resolution | Status |
|---|-------|------------|--------|
| 1 | Strimzi `watchNamespaces="{*}"` YAML parse error | Used `watchAnyNamespace=true` instead | FIXED |
| 2 | Keycloak ingress backend port was `80`, should be `8080` | Edited template `keycloak.yaml` | FIXED |
| 3 | Helm chart Kafka template used `group: azul-kafka-kafkactl` which is not a valid Strimzi resource group | Added `name` field alongside `group` in kafkactl deployment | FIXED |
| 4 | OpenSearch dashboard `multiple_auth_enabled` not propagated to configmap | Operator eventually picked it up from CRD additionalConfig after reconciliation | FIXED |
| 5 | Pods can't resolve `*.kp.local` DNS inside cluster | Added `hosts` block to CoreDNS Corefile with static entries | FIXED |
| 6 | Dashboard OIDC: `DEPTH_ZERO_SELF_SIGNED_CERT` connecting to Keycloak | Created cert-manager Certificate for keycloak-tls using OpenSearch CA issuer; mounted CA cert into dashboards via additionalVolumes + NODE_EXTRA_CA_CERTS env var | FIXED |
| 7 | Dashboard template missing `additionalVolumes` support | Added `{{- if .Values.opensearch.dashboard.additionalVolumes }}` block to opensearch.yaml template | FIXED |
| 8 | OpenSearch template missing `general.additionalConfig` support | Added `{{- if .Values.opensearch.general.additionalConfig }}` block to opensearch.yaml template | FIXED |
| 9 | OpenSearch single-node cluster: `cluster_manager_not_discovered_exception` after operator removes bootstrap pod | Used `opensearch-node unsafe-bootstrap` tool to reset voting config (see section 1.7.5) | FIXED |
| 10 | `discovery.type: single-node` conflicts with `cluster.initial_master_nodes` | OpenSearch 3.2.0 rejects this combination; removed discovery.type and used unsafe-bootstrap instead | FIXED |
| 11 | OpenSearch data node `AccessDeniedException: /usr/share/opensearch/data/nodes` | Resolved by deleting pod to trigger fresh init containers with chown | FIXED |
| 12 | securityadmin timeout (`H2StreamResetException`) | Root cause was no data nodes (cluster RED); once data node started, securityadmin completed | FIXED |
| 13 | App chart 10.0.0-unstable images not on Docker Hub | `main` branch uses unstable image tags not publicly available; switched to stable `azul-9.0.0` git tag | FIXED |
| 14 | 9.0.0 chart schema rejects extra values | Removed `consumerGroupRetentionDays`, `origin_alt_name`, `azulReportFeeds` from values file | FIXED |
| 15 | CORS values with JSON brackets break YAML template rendering | Changed CORS values to defaults: `"[]"` instead of `'["https://azul.kp.local"]'` | FIXED |
| 16 | Keycloak 26.x JWT missing `sub` claim — restapi rejects with "JWT does not have a subject" | Added `oidc-sub-mapper` to the `azul` client scope in Keycloak (see section 1.7.6). Updated `setup-keycloak.sh` | FIXED |
| 17 | OpenSearch OIDC 401 "Authentication finally failed" — can't validate Keycloak JWT | OpenSearch's `ca-certificates` bundle only had public CAs (Mozilla bundle), not the self-signed Test CA that signs the Keycloak TLS cert. Appended Test CA to the `azul-opensearch-certs` configmap (see section 1.7.7) | FIXED |
| 18 | CPU request exhaustion with 60+ plugin pods (all nodes 100%) | LimitRange default 50m CPU × 60+ pods exceeds 4-worker capacity. Reduced to 10m (section 3.2). Scale-to-zero then scale-to-one required to pick up new LimitRange | FIXED |
| 19 | YARA-X compile error with public `Yara-Rules/rules` repo | Classic YARA syntax (`pe.exports()` returns boolean) incompatible with YARA-X (expects integer). Removed source; yara-x enabled with empty sources | FIXED |
| 20 | Tika 2-container pod unschedulable — CPU request = limit | K8s defaults requests=limits when only limits set. Tika got 500m CPU request × 2 containers = 1000m. Added explicit 10m requests | FIXED |
| 21 | Backup pod Pending — 250m CPU / 2Gi memory too high for packed cluster | Reduced backup/restore resource requests to 10m CPU / 512Mi memory (limits stay 500m/2Gi) in both azul-values.yaml and azul-values-core.yaml | FIXED |
| 22 | Redis secret missing `redis-username` key — dispatchers CreateContainerConfigError | Chart expects keys named `redis-username`, `redis-password`, AND `password`. Recreated secret with all 3 keys. Updated deploy script | FIXED |
| 23 | Helm configmap field manager conflict on `azul-opensearch-certs` after manual Test CA append | `helm upgrade azul-infra` fails with "conflict with kubectl-client-side-apply using v1". Fix: use `kubectl apply --server-side --field-manager=helm --force-conflicts` when appending Test CA. Updated deploy script | FIXED |
| 24 | Cannot log in via browser — Pi-hole missing Azul DNS records | Pi-hole only had `unifi.kp.local`. Added: `azul.kp.local`, `keycloak-azul.kp.local`, `opensearch-azul.kp.local`, `minio-azul.kp.local`, `minio-api-azul.kp.local` → `192.168.66.201` | FIXED |
| 25 | `azul-web-tls` TLS cert missing — nginx serving Fake Certificate for azul.kp.local | Web ingress referenced `azul-web-tls` secret but it didn't exist. Created cert-manager Certificate using Test CA issuer (copied CA secret + Issuer to azul namespace). See section 5.1 | FIXED |
| 26 | OIDC scopes wrong — missing `offline_access` and `roles` | Official docs specify `openid profile offline_access roles azul` for Keycloak. Was `openid profile email azul`. Without `offline_access` no refresh tokens; without `roles` RBAC may not work. Fixed in both values files + helm upgrade | FIXED |
| 27 | `grep -c` exit code 1 when count is 0 — breaks deploy script conditionals | `grep -c "X" \|\| echo "0"` produces `"0\n0"` (not `"0"`) because grep outputs 0, exits 1, then echo appends 0. Fix: `var=$(...) \|\| var="0"` with `[ "$var" -gt 0 ]` comparison. 6 instances fixed in azul-deploy.sh | FIXED |
| 28 | OpenSearch node ID changes on pod restart — requires unsafe-bootstrap every time | Deleting/restarting the OpenSearch pod changes its node ID. The voting config in PVC references the old ID, causing `cluster_manager_not_discovered_exception`. Fix: always run `run_opensearch_bootstrap` (scale down → unsafe-bootstrap job → scale up) instead of simple pod delete. Updated deploy script | FIXED |
| 29 | Stale `opensearch-ca.crt` file from previous deploy | Deploy script checked `if [ ! -f "$OPENSEARCH_CA" ]` and skipped extraction if file existed. On redeploy, old CA was used. Fix: always extract CA from the new cluster's secret | FIXED |
| 30 | Plugin deployment name pattern mismatch in deploy script | Script grepped for `office-`, `tika`, etc. but actual names are `plugin-office-*`, `plugin-tika`. Fix: simplified to `grep -E "^plugin-"` | FIXED |
| 31 | Restore job status check infinite loop — `conditions[0].type` is `SuccessCriteriaMet` not `Complete` | K8s Job has `SuccessCriteriaMet` at conditions[0] and `Complete` at [1]. Script only checked [0] for "Complete". Fix: iterate all conditions with `{range .status.conditions[*]}` | FIXED |
| 32 | Keycloak `roles` scope not assigned to azul-web client | Built-in `roles` scope exists in Keycloak but wasn't added as optional scope to `azul-web` client. OIDC token request with `roles` scope returned HTTP 400 "Invalid scopes". Fix: added explicit PUT to assign `roles` as optional scope in setup-keycloak.sh | FIXED |
| 33 | Keycloak `audience` client scope missing audience mapper | The `audience` client scope was created empty (no mappers). Access tokens had `aud: "account"` instead of `aud: "azul-web"`. RestAPI rejected with "Invalid audience". Fix: added `oidc-audience-mapper` with `included.client.audience: azul-web` in setup-keycloak.sh | FIXED |
| 34 | `helm upgrade azul` strips Test CA from opensearch-certs configmap | Helm upgrade regenerates configmaps from chart values, losing the appended Test CA. OpenSearch then can't validate Keycloak TLS → OIDC auth fails → API 500. Fix: added `reapply_test_ca()` function in backup, restore, and deploy scripts that re-appends after each helm upgrade | FIXED |

---

## Credentials Summary

All credentials saved to `/data/AZUL/.azul-credentials` (mode 600).

| Service | Username | Source |
|---------|----------|--------|
| OpenSearch Admin | admin | Secret: `azul-cluster-admincredentials` |
| OpenSearch Dashboards | kibanaserver | Secret: `azul-cluster-dashboardcredentials` |
| MinIO | minioadmin | Secret: `s3-keys` |
| Keycloak Admin | admin | Secret: `keycloak` (key: KEYCLOAK_ADMIN_PASSWORD) |
| Keycloak Test User | basic / basic12345 | Created via setup-keycloak.sh |
| Keycloak Admin User | azuladmin / admin12345 | Created via setup-keycloak.sh |
| OpenSearch Dashboards OIDC | opensearch-dashboards | Client secret: `opensearch-dashboards-secret` |

---

## Stage 2: Azul Application

### 2.1 Chart Version Selection (IMPORTANT)

**Status**: COMPLETED

The repo's `main` branch contains chart version `10.0.0-unstable` which references unstable image tags (e.g., `dispatcher:20260209T2251-unstable@sha256:...`). These images are **NOT publicly available** on Docker Hub - only the stable `9.0.0` tag exists for each image.

**Solution**: Checkout the stable `azul-9.0.0` tag before deploying the app chart:

```bash
cd /data/AZUL/azul-app
git checkout azul-9.0.0
```

**Note**: The infra chart is still deployed from `main` branch (10.0.0-unstable) since it uses standard upstream images (OpenSearch, Kafka, MinIO, Keycloak) that are all publicly available. Only the AZUL-specific app images require the stable tag.

**Docker Hub org**: `docker.io/asdazul/` (56 repositories, all with `9.0.0` tag)

### 2.2 Namespace & Secrets Creation

**Status**: COMPLETED

**Namespace**: `azul` (created manually)

```bash
kubectl create namespace azul
```

**Secrets created**:

```bash
# Copy MinIO keys from infra namespace
kubectl get secret s3-keys -n azul-infra -o json \
  | jq '.metadata.namespace = "azul" | del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp)' \
  | kubectl apply -f -

# Redis password (MUST include redis-username and redis-password keys — Issue #22)
REDIS_PASS=$(openssl rand -base64 16)
kubectl create secret generic redis -n azul \
  --from-literal=redis-username="" \
  --from-literal=redis-password="$REDIS_PASS" \
  --from-literal=password="$REDIS_PASS"

# OpenSearch writer credentials (bcrypt hashed, must match azul-infra-values.yaml internal_users)
WRITER_PASSWORD=$(openssl rand -base64 16)
WRITER_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$WRITER_PASSWORD', bcrypt.gensalt()).decode())")
kubectl create secret generic metastore-creds -n azul \
  --from-literal=writer="$WRITER_PASSWORD"

# Then update azul-infra-values.yaml with the bcrypt hash for azul_writer and helm upgrade
```

**CA Certificate ConfigMap** (for trusting OpenSearch self-signed cert):

```bash
kubectl create configmap azul-ca-cert -n azul \
  --from-file=ca.crt=/data/AZUL/opensearch-ca.crt
```

### 2.3 Values File Schema Compatibility

**Status**: COMPLETED

The 9.0.0 chart has a JSON schema (`values.schema.json`) that rejects unknown properties. The following values from the 10.0.0-unstable example had to be removed:

| Removed Property | Section | Reason |
|-----------------|---------|--------|
| `consumerGroupRetentionDays` | `external.kafka` | Not in 9.0.0 schema |
| `origin_alt_name` | `security.labels.releasability` | Not in 9.0.0 schema |
| `azulReportFeeds` | `secrets` | Not in 9.0.0 schema |

### 2.4 App Helm Chart Deployment

**Status**: COMPLETED (revision 1)

**Release Name**: azul
**Chart**: /data/AZUL/azul-app/azul (tag: azul-9.0.0)
**Namespace**: azul
**Custom Values**: /data/AZUL/azul-values.yaml

```bash
helm install azul /data/AZUL/azul-app/azul \
  -n azul \
  -f /data/AZUL/azul-values.yaml
```

**Key configuration choices**:
- Plugins enabled (see Stage 3 for details)
- Single replica for all components (homelab)
- OIDC enabled with Keycloak (`authority_url: https://keycloak-azul.kp.local/realms/azul`)
- OpenSearch indices: 1 shard, 0 replicas (single-node cluster)
- Reduced resource limits (256Mi-1Gi memory per component)
- Two sources configured: `testing` and `samples`
- CORS defaults (`[]`) to avoid YAML template rendering issues

### 2.5 Running Pods (azul namespace)

| Pod | Ready | Component | Notes |
|-----|-------|-----------|-------|
| azul-redis-master-0 | 1/1 | Redis cache | StatefulSet |
| docs-* | 1/1 | API documentation (nginx) | |
| dp-metastore-events-* | 1/1 | Dispatcher: metastore event routing | |
| dp-metastore-streams-* | 1/1 | Dispatcher: metastore stream routing | |
| dp-plugin-events-* | 1/1 | Dispatcher: plugin event routing | |
| dp-plugin-streams-* | 1/1 | Dispatcher: plugin stream routing | |
| dp-lost-tasks-* | 1/1 | Lost task recovery | |
| ms-ageoff-* | 1/1 | Metastore: data age-off | |
| ms-ingest-binary-* | 1/1 | Metastore: binary ingest to OpenSearch | |
| ms-ingest-plugin-* | 1/1 | Metastore: plugin result ingest | |
| ms-ingest-status-* | 1/1 | Metastore: status ingest | |
| restapi-0 | 1/1 | REST API server (uvicorn) | StatefulSet |
| webui-* | 1/1 | Angular web UI (nginx) | |

**Startup behavior**: Metastore ingest pods crash-loop 3-4 times during initial startup while dispatchers initialize their Kafka connections. This is expected and self-resolves within ~2 minutes.

### 2.6 Endpoint Verification

| URL | Service | Response | Notes |
|-----|---------|----------|-------|
| https://azul.kp.local/ | Web UI | 302 → /ui/ | Angular SPA loads correctly |
| https://azul.kp.local/ui/ | Web UI | 200 | Full HTML page served |
| https://azul.kp.local/api | REST API | 200 | API root accessible |
| https://azul.kp.local/api/ | REST API | 307 → /api | Trailing slash redirect |

### 2.7 Credentials Summary (Stage 2)

| Service | Secret Name | Key | Notes |
|---------|-------------|-----|-------|
| Redis | `redis` | `redis-username`, `redis-password`, `password` | All 3 keys required (Issue #22) |
| OpenSearch Writer | `metastore-creds` | `writer` | Bcrypt hash in azul-infra internal_users |
| MinIO | `s3-keys` | `accesskey`/`secretkey` | Copied from azul-infra |
| Backup S3 | `s3-backup-keys` | `access_key`/`secret_key` | External MinIO creds |

All passwords saved to `/data/AZUL/.azul-credentials`

---

## Stage 3: Plugins

**Status**: COMPLETED (revision 4)

### 3.1 Plugin Enablement

Enabled 6 of 12 plugin groups. The remaining 6 require external services, API keys, or impractically large storage.

**Enabled Plugin Groups**:

| Group | Type | Pods | Description |
|-------|------|------|-------------|
| office | standard | 8 | Office doc analysis: DDE, decrypt, macros, MIME, OLE, OpenXML, RTF, SYLK |
| tika | standard | 1 (2 containers) | Apache Tika metadata extraction with sidecar server |
| generic | standard | 40 | LIEF (ELF/PE/Mach-O), PDF tools, email, exiftool, FLOSS, Ghidra, CAPA, unbox, etc. |
| yara-x | yara-x | 0 | Enabled but no sources (public YARA repos incompatible with YARA-X syntax) |
| suricata | suricata | 0 | Enabled but no rule sources configured yet |
| maco | maco | 0 | Enabled but no extractor sources configured yet |

**Disabled Plugin Groups**:

| Group | Reason |
|-------|--------|
| assemblyline | Requires external Assemblyline instance + API credentials |
| dynamic (CAPE) | Requires external CAPE sandbox server |
| virustotal | Requires VirusTotal API key |
| nsrl | Requires 256Gi PVC for NSRL database download |
| retrohunt | Requires 1000Gi PVC for content indexing |
| report-feeds | Not open-sourced yet (stated in chart comments) |

### 3.2 Resource Adjustments for Homelab

- **LimitRange default CPU request**: Reduced from 50m to 10m per container (light plugins are mostly idle, waiting for Kafka messages)
- **Heavy plugins**: Reduced memory requests from chart defaults to fit homelab:
  - mandiant-capa: 2Gi req / 4Gi limit (default: 6Gi/6Gi)
  - floss: 2Gi / 4Gi (default: 4Gi/4Gi)
  - ghidra: 2Gi / 4Gi (default: 4Gi/4Gi)
  - exiftool: 1Gi / 2Gi (default: 2Gi/4Gi)
  - unbox: 2Gi / 4Gi (default: 4Gi/8Gi)
  - entrypointcheck: 200Mi / 2Gi (default: 200Mi/4Gi)
- **Tika**: Explicit 10m CPU / 200Mi memory requests on both containers (setting only limits causes K8s to default requests=limits)

### 3.3 Deployment

```bash
# Enable plugins (revision 4)
helm upgrade azul /data/AZUL/azul-app/azul -n azul -f /data/AZUL/azul-values.yaml
```

### 3.4 Running Pods (azul namespace - after plugins)

Total: 63 pods (13 core + 50 plugin)

**Plugin pods** (all 1/1 Ready, 0 restarts):
- 8x office: office-dde, office-decrypt, office-macros, office-mimeinfo, office-oleinfo, office-openxmlinfo, office-rtfinfo, office-sylk
- 1x tika: tika (2/2 containers: main + tika-server sidecar)
- 40x generic: alphabets, android-parser, build-time-strings, mandiant-capa, certificates, debloat, de4dot, dotnet-decompiler, dotnet-deob, email-headers, email-mimedecoder, email-olemail, entropy, entrypointcheck, exiftool, export-hashes, floss, ghidra, goinfo, image-convert, index-coincidence, js-deobf, lief-elf, lief-fatmacho, lief-macho, lief-pe, lookback-hash, lookback-search, malcarve, netinfo, pdftools-pdfid, pdftools-pdfinfo, pdftools-pdftext, portex, qrcode, python, repeated-bytes, richid, script-decoder, shortcut, unbox
- 1x yara-x: (no pods - enabled but no sources)
- 0x suricata: (no pods - enabled but no sources)
- 0x maco: (no pods - enabled but no sources)

### 3.5 Issues Encountered

**Issue #18: CPU request exhaustion**
- All 4 worker nodes hit 100% CPU requests with default 50m per container × 60+ pods
- Fix: Reduced LimitRange default CPU request from 50m to 10m (plugins are mostly idle)
- Required scale-to-zero then scale-to-one to pick up new LimitRange defaults (rolling update deadlock)

**Issue #19: YARA-X incompatible public rules**
- The `Yara-Rules/rules` GitHub repo uses classic YARA syntax (`pe.exports()` returns boolean)
- YARA-X expects integer type, causing `CompileError: wrong type`
- Fix: Removed the source; yara-x enabled with empty sources for future use

**Issue #20: Tika CPU request = limits**
- Setting only `limits` without `requests` on containers causes K8s to default requests=limits
- Tika's two containers each got 500m CPU requests (1000m total), exceeding node capacity
- Fix: Added explicit low CPU requests (10m) alongside the limits

---

## Stage 4: Backup & Lifecycle Scripts

**Status**: COMPLETED

### 4.1 Backup Architecture

Azul has a **built-in backup mechanism** (`asdazul/backup:9.0.0`):
- **Backup mode**: Deploys a continuous pod that subscribes to Kafka topics and copies all events + binary streams to an external S3 endpoint
- **Restore mode**: Creates a one-shot Job that replays streams then events back into the system
- OpenSearch indices are **NOT backed up directly** — they rebuild automatically when events are replayed during restore
- Redis is ephemeral cache — no backup needed
- Keycloak config is reproducible via `setup-keycloak.sh`

The backup target is an **external MinIO** instance running on the host machine (outside K8s), managed via docker-compose/podman-compose.

### 4.2 External MinIO Backup Target

**File**: `/data/AZUL/docker-compose-backup.yaml`

```bash
# Start external MinIO
docker compose -f /data/AZUL/docker-compose-backup.yaml up -d
# Or with podman
podman-compose -f /data/AZUL/docker-compose-backup.yaml up -d
```

| Setting | Value |
|---------|-------|
| S3 API port | 9100 (mapped from 9000) |
| Console port | 9101 |
| Credentials | azul-backup / azul-backup-secret |
| Data directory | /data/backups/azul-minio/ |
| Console URL | http://192.168.66.41:9101 |

### 4.3 Backup Configuration in azul-values.yaml

```yaml
recovery:
  mode: "off"                              # off | backup | restore
  restoreType: "all"
  externalS3Endpoint: "192.168.66.41:9100" # Host IP:port (NO http/https prefix)
  externalS3Secure: "false"                # Plain HTTP for local MinIO
  label: "01"                              # Changing label starts fresh backup
  bucketNamePrefix: "azul-backup-"         # Creates: azul-backup-01-streams, azul-backup-01-events
```

K8s secret `s3-backup-keys` in azul namespace provides `access_key` and `secret_key` to the backup/restore pod.

### 4.4 Scripts

All scripts work on **Ubuntu 22.04+** and **RHEL 9+**. They use bash, kubectl, helm, curl, python3 (no jq/yq required).

| Script | Purpose | Usage |
|--------|---------|-------|
| `azul-backup.sh` | Start/stop continuous backup to external MinIO | `./azul-backup.sh [start\|stop\|status]` |
| `azul-teardown.sh` | Remove all Azul resources from cluster | `./azul-teardown.sh [--force]` |
| `azul-deploy.sh` | 3-stage deploy with health checks | `./azul-deploy.sh {all\|infra\|app\|plugins}` |
| `azul-restore.sh` | Restore from external MinIO backup | `./azul-restore.sh [--check] [--label ID]` |

**Backup workflow**:
```bash
/data/AZUL/scripts/azul-backup.sh start     # Starts external MinIO + backup pod
/data/AZUL/scripts/azul-backup.sh status    # Check backup progress
/data/AZUL/scripts/azul-backup.sh stop      # Stop backup (data preserved)
```

**Full lifecycle (teardown + redeploy)**:
```bash
/data/AZUL/scripts/azul-backup.sh start     # Back up everything first
# ... wait for backup data to accumulate ...
/data/AZUL/scripts/azul-backup.sh stop      # Stop backup

/data/AZUL/scripts/azul-teardown.sh         # Wipe all 4 namespaces + operators + CRDs
/data/AZUL/scripts/azul-deploy.sh all       # 3-stage redeploy (infra → app → plugins)
/data/AZUL/scripts/azul-restore.sh          # Restore data from backup
```

**Individual deploy stages**:
```bash
/data/AZUL/scripts/azul-deploy.sh infra     # Stage 1: operators + Kafka/OpenSearch/MinIO/Keycloak
/data/AZUL/scripts/azul-deploy.sh app       # Stage 2: core app (13 pods, no plugins)
/data/AZUL/scripts/azul-deploy.sh plugins   # Stage 3: all plugins (50 pods)
```

### 4.5 Deploy Stage Details

**Stage 1 (infra)** performs:
1. Install Strimzi + OpenSearch operators
2. Create azul-infra namespace + secrets (from `.azul-credentials`)
3. `helm install azul-infra`
4. Wait for Kafka, OpenSearch, MinIO, Keycloak, Postgres
5. OpenSearch single-node unsafe-bootstrap (if needed)
6. CoreDNS hosts block
7. Keycloak TLS cert (cert-manager)
8. Append Test CA to OpenSearch certs configmap
9. Run `setup-keycloak.sh`
10. Verify: all infra pods, Keycloak realm, OpenSearch health

**Stage 2 (app)** performs:
1. Create azul namespace + secrets + CA configmap
2. `helm install azul` using `azul-values-core.yaml` (pluginsEnabled: false)
3. Wait for 13 core pods
4. Verify: Web UI HTTP 200/302, OAuth token, API /users/me 200

**Stage 3 (plugins)** performs:
1. `helm upgrade azul` using `azul-values.yaml` (pluginsEnabled: true)
2. Scale-to-zero/one for LimitRange CPU workaround
3. Wait for all ~63 pods
4. Verify: all Running, 0 CrashLoopBackOff

### 4.6 Values Files

| File | Purpose | pluginsEnabled |
|------|---------|---------------|
| `azul-values-core.yaml` | Stage 2 deploy (core only) | false |
| `azul-values.yaml` | Stage 3 deploy (core + all plugins) | true |

Both files are identical except for the plugins section. `azul-values-core.yaml` has `pluginsEnabled: false` and `plugins: {}`.

### 4.7 Discord Notifications

All scripts send Discord notifications on success/failure using the shared webhook. Notifications include operation, status, date, and details.

---

## Stage 5: Post-Deploy Fixes

### 5.1 Azul Web TLS Certificate (CRITICAL)

**Status**: COMPLETED

**Problem**: The web ingress references `azul-web-tls` secret for TLS, but this secret is not created by the Helm chart. Without it, nginx serves its default "Fake Certificate" which causes browser TLS warnings and may break the OIDC redirect flow.

**Solution**: Create a cert-manager Certificate in the `azul` namespace. Since the CA issuer is in `azul-infra`, we need to copy the CA secret and create a namespace-scoped Issuer:

```bash
# 1. Copy CA secret from azul-infra to azul namespace
kubectl get secret azul-opensearch-ca-cert -n azul-infra -o json \
  | python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata'] = {'name': 'azul-opensearch-ca-cert', 'namespace': 'azul'}
print(json.dumps(s))
" | kubectl apply -f -

# 2. Create an Issuer in azul namespace
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

# 3. Create the certificate
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

# 4. Verify
kubectl get certificate azul-web-tls -n azul
# Should show READY=True within seconds
```

**Verification**: `echo | openssl s_client -connect 192.168.66.201:443 -servername azul.kp.local 2>/dev/null | openssl x509 -noout -issuer` should show `issuer=CN = Test CA` (not "Kubernetes Ingress Controller Fake Certificate").

### 5.2 Pi-hole DNS Records (CRITICAL)

**Status**: NEEDS MANUAL ACTION

**Problem**: The browser-based OIDC login flow requires DNS resolution for both `azul.kp.local` (Web UI) and `keycloak-azul.kp.local` (auth redirect). Pi-hole was missing all Azul DNS entries.

**Required Pi-hole Local DNS Records** (Pi-hole Admin → Local DNS → DNS Records):

| Hostname | IP |
|----------|-----|
| `azul.kp.local` | `192.168.66.201` |
| `keycloak-azul.kp.local` | `192.168.66.201` |
| `opensearch-azul.kp.local` | `192.168.66.201` |
| `minio-azul.kp.local` | `192.168.66.201` |
| `minio-api-azul.kp.local` | `192.168.66.201` |

Without these records, the browser can reach `azul.kp.local` but when it redirects to Keycloak for login, the browser can't resolve `keycloak-azul.kp.local` and the login fails.

**Note**: The management server (`kp-svr-01`, `192.168.66.41`) uses `1.1.1.1` / `8.8.8.8` as DNS, not Pi-hole. For server-side testing, use `curl --resolve` or add entries to `/etc/hosts`.

---

## Backup, Teardown & Rebuild Runbook

This runbook documents every command needed for a full Azul lifecycle: backup, teardown, redeploy, and restore. It was validated end-to-end on 2026-02-12.

**Prerequisites**:
- All `/data/AZUL/` files in place (charts, values, scripts, credentials)
- `kubectl`, `helm`, `python3`, `curl`, `openssl` in PATH
- `python3 -c "import bcrypt"` works (install with `pip3 install bcrypt`)
- Docker or Podman available on host
- Helm repos added: `strimzi`, `opensearch-operator`
- Talos PodSecurity exemptions applied for: `kafka`, `opensearch-operator`, `azul-infra`, `azul`

### Step 1: Backup

#### 1a. Start External MinIO

```bash
# Start the backup MinIO on the host (outside K8s)
docker compose -f /data/AZUL/docker-compose-backup.yaml up -d

# Verify it's healthy
curl -sf http://localhost:9100/minio/health/live && echo "OK"

# Console: http://192.168.66.41:9101 (azul-backup / azul-backup-secret)
```

#### 1b. Export Keycloak Configuration (Manual Backup)

The Keycloak realm is reproducible via `setup-keycloak.sh`, but exporting preserves any manual changes:

```bash
# Port-forward to Keycloak
kubectl port-forward svc/keycloak -n azul-infra 8443:8443 &
PF_PID=$!
sleep 3

# Get admin token
KC_ADMIN_PASS=$(grep KC_ADMIN_PASSWORD /data/AZUL/.azul-credentials | cut -d= -f2)
KC_TOKEN=$(curl -k -s -X POST "https://localhost:8443/realms/master/protocol/openid-connect/token" \
  -d "username=admin&password=${KC_ADMIN_PASS}&grant_type=password&client_id=admin-cli" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Export realm
curl -k -s "https://localhost:8443/admin/realms/azul" \
  -H "Authorization: Bearer $KC_TOKEN" > /data/AZUL/keycloak-realm-export.json

# Export users
curl -k -s "https://localhost:8443/admin/realms/azul/users" \
  -H "Authorization: Bearer $KC_TOKEN" > /data/AZUL/keycloak-users-export.json

kill $PF_PID 2>/dev/null
```

#### 1c. Create Backup Secret & Start Backup

```bash
# Create s3-backup-keys secret (if not exists)
kubectl create secret generic s3-backup-keys -n azul \
  --from-literal=access_key="azul-backup" \
  --from-literal=secret_key="azul-backup-secret" 2>/dev/null || true

# Set recovery.mode to "backup" in azul-values.yaml
sed -i 's/^  mode: .*/  mode: "backup"/' /data/AZUL/azul-values.yaml

# Deploy backup pod
helm upgrade azul /data/AZUL/azul-app/azul -n azul -f /data/AZUL/azul-values.yaml --timeout 5m

# Verify backup pod is running
kubectl get pods -n azul -l "app.kubernetes.io/component=recovery-backup"

# Check backup logs
kubectl logs -n azul -l "app.kubernetes.io/component=recovery-backup" --tail=20

# Check backup data on disk
du -sh /data/backups/azul-minio/azul-backup-01-*
```

> **CRITICAL**: Backup pod resource requests must be low (10m CPU / 512Mi memory) or it will stay Pending on a packed cluster. This is already configured in the values files (Issue #21).

#### 1d. Stop Backup

```bash
# Set mode back to off
sed -i 's/^  mode: .*/  mode: "off"/' /data/AZUL/azul-values.yaml
helm upgrade azul /data/AZUL/azul-app/azul -n azul -f /data/AZUL/azul-values.yaml --timeout 5m

# Verify backup pod is gone
kubectl get pods -n azul -l "app.kubernetes.io/component=recovery-backup"
```

**Or use the script**: `/data/AZUL/scripts/azul-backup.sh start` / `stop` / `status`

---

### Step 2: Teardown

#### 2a. Uninstall Helm Releases

```bash
# Uninstall app release (removes all azul pods)
helm uninstall azul -n azul --timeout 5m

# Uninstall infra release (removes Kafka, OpenSearch, MinIO, Keycloak, Postgres)
helm uninstall azul-infra -n azul-infra --timeout 5m
```

#### 2b. Delete PVCs

```bash
# Delete all PVCs in both namespaces
kubectl delete pvc --all -n azul
kubectl delete pvc --all -n azul-infra
```

#### 2c. Delete Namespaces

```bash
kubectl delete namespace azul --timeout=120s
kubectl delete namespace azul-infra --timeout=120s
```

#### 2d. Uninstall Operators

```bash
helm uninstall strimzi-kafka-operator -n kafka --timeout 3m
helm uninstall opensearch-operator -n opensearch-operator --timeout 3m
```

#### 2e. Delete CRDs and Operator Namespaces

```bash
# Delete Strimzi CRDs
kubectl get crds -o name | grep strimzi.io | xargs kubectl delete

# Delete OpenSearch CRDs
kubectl get crds -o name | grep opensearch | xargs kubectl delete

# Delete operator namespaces
kubectl delete namespace kafka --timeout=60s
kubectl delete namespace opensearch-operator --timeout=60s
```

#### 2f. Clean CoreDNS

```bash
# Edit CoreDNS configmap and remove the hosts block containing azul entries
kubectl edit configmap coredns -n kube-system
# Remove the entire "hosts { ... }" block with azul entries
kubectl rollout restart deployment coredns -n kube-system
```

**Or use the script**: `/data/AZUL/scripts/azul-teardown.sh` (or `--force` to skip confirmation)

---

### Step 3: Validate Clean State

```bash
# All 4 azul namespaces should be gone
kubectl get namespaces | grep -E "azul|kafka|opensearch"

# No Strimzi or OpenSearch CRDs
kubectl get crds | grep -E "strimzi|opensearch"

# No azul helm releases
helm list -A | grep -E "azul|strimzi|opensearch"

# External MinIO still running (data preserved)
curl -sf http://localhost:9100/minio/health/live && echo "MinIO: OK"
du -sh /data/backups/azul-minio/
```

---

### Step 4: Redeploy Infrastructure (Stage 1)

#### 4a. Install Operators

```bash
helm install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace kafka --create-namespace \
  --set watchAnyNamespace=true \
  --version 0.50.0 --timeout 3m

helm install opensearch-operator opensearch-operator/opensearch-operator \
  --namespace opensearch-operator --create-namespace \
  --version 2.8.0 --timeout 3m

# Wait for operators to be ready
kubectl wait --for=condition=ready pod -l name=strimzi-cluster-operator -n kafka --timeout=120s
kubectl wait --for=condition=ready pod -l control-plane=controller-manager -n opensearch-operator --timeout=120s
```

#### 4b. Create Namespace and Secrets

```bash
kubectl create namespace azul-infra

# Source credentials
source <(grep -v '^#' /data/AZUL/.azul-credentials | grep -v '^$' | sed 's/^/export /')

# Create secrets
kubectl create secret generic s3-keys -n azul-infra \
  --from-literal=accesskey="$S3_ACCESS_KEY" \
  --from-literal=secretkey="$S3_SECRET_KEY"

kubectl create secret generic azul-cluster-admincredentials -n azul-infra \
  --from-literal=username=admin \
  --from-literal=password="$OS_ADMIN_PASS"

kubectl create secret generic azul-cluster-dashboardcredentials -n azul-infra \
  --from-literal=username=kibanaserver \
  --from-literal=password="$OS_DASH_PASS"

kubectl create secret generic keycloak -n azul-infra \
  --from-literal=DB_PASSWORD="$KC_DB_PASSWORD" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD"
```

#### 4c. Deploy Infra Chart

```bash
helm install azul-infra /data/AZUL/azul-app/infra \
  -n azul-infra -f /data/AZUL/azul-infra-values.yaml --timeout 10m
```

#### 4d. Wait for Pods (order: Kafka → MinIO → Postgres → Keycloak → OpenSearch)

```bash
kubectl wait --for=condition=ready pod -l strimzi.io/component-type=kafka -n azul-infra --timeout=300s
kubectl wait --for=condition=ready pod -l app=minio -n azul-infra --timeout=180s
kubectl wait --for=condition=ready pod -l app=postgres -n azul-infra --timeout=180s
kubectl wait --for=condition=ready pod -l app=keycloak -n azul-infra --timeout=300s

# Check OpenSearch — it usually needs the unsafe-bootstrap fix for single-node
sleep 30
kubectl get pod azul-opensearch-nodes-0 -n azul-infra
```

#### 4e. OpenSearch Unsafe-Bootstrap (Single-Node Clusters)

If OpenSearch shows `ClusterManagerNotDiscoveredException` or stays not Ready:

```bash
# Scale down operator and OpenSearch
kubectl scale deployment opensearch-operator-controller-manager -n opensearch-operator --replicas=0
kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=0
sleep 15

# Run unsafe-bootstrap
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

kubectl wait --for=condition=complete job/opensearch-unsafe-bootstrap -n azul-infra --timeout=120s
kubectl delete job opensearch-unsafe-bootstrap -n azul-infra

# Restore replicas
kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=1
kubectl scale deployment opensearch-operator-controller-manager -n opensearch-operator --replicas=1
kubectl wait --for=condition=ready pod/azul-opensearch-nodes-0 -n azul-infra --timeout=180s
```

#### 4f. CoreDNS Hosts Block

```bash
# Get current Corefile, add hosts block, apply
# The deploy script automates this. Manual way:
kubectl edit configmap coredns -n kube-system
# Add inside the .:53 block, before the "forward" line:
#     hosts {
#         192.168.66.201 keycloak-azul.kp.local
#         192.168.66.201 opensearch-azul.kp.local
#         192.168.66.201 azul.kp.local
#         fallthrough
#     }
kubectl rollout restart deployment coredns -n kube-system
```

#### 4g. Keycloak TLS Certificate

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

#### 4h. Append Test CA to OpenSearch Certs ConfigMap

> **CRITICAL**: Use `--server-side --field-manager=helm --force-conflicts` to avoid helm upgrade conflicts later (Issue #23).

```bash
# Extract Test CA
kubectl get secret azul-opensearch-ca-cert -n azul-infra \
  -o "jsonpath={.data.tls\.crt}" | base64 -d > /tmp/test-ca.pem

# Get current CA bundle
kubectl get configmap azul-opensearch-certs -n azul-infra \
  -o "jsonpath={.data.ca-certificates}" > /tmp/os-ca-bundle.pem

# Append Test CA
echo "" >> /tmp/os-ca-bundle.pem
echo "# Homelab Test CA (signs Keycloak TLS cert)" >> /tmp/os-ca-bundle.pem
cat /tmp/test-ca.pem >> /tmp/os-ca-bundle.pem

# Update configmap with server-side apply (avoids field manager conflicts)
kubectl create configmap azul-opensearch-certs -n azul-infra \
  --from-file=ca-certificates=/tmp/os-ca-bundle.pem \
  --dry-run=client -o yaml | kubectl apply --server-side --field-manager=helm --force-conflicts -f -

# Restart OpenSearch to pick up the new CA bundle
kubectl delete pod azul-opensearch-nodes-0 -n azul-infra
kubectl wait --for=condition=Ready pod/azul-opensearch-nodes-0 -n azul-infra --timeout=180s

rm -f /tmp/test-ca.pem /tmp/os-ca-bundle.pem
```

Also save the CA cert for the app namespace:
```bash
kubectl get secret azul-opensearch-ca-cert -n azul-infra \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /data/AZUL/opensearch-ca.crt
```

#### 4i. Keycloak Realm Setup

```bash
bash /data/AZUL/setup-keycloak.sh
```

This creates: realm `azul`, roles, groups, clients (`azul-web`, `opensearch-dashboards`, `azul-service`), test user `basic/basic12345`, admin user `azuladmin/admin12345`, subject claim mapper.

> **NOTE**: The script uses `kubectl port-forward` with a 2-minute default timeout. If it times out before completing all steps, manually verify and complete using the Keycloak Admin Console at `https://keycloak-azul.kp.local`.

#### 4j. Verify Stage 1

```bash
# All infra pods running
kubectl get pods -n azul-infra

# Keycloak realm accessible
curl -k -s -o /dev/null -w "%{http_code}\n" -H "Host: keycloak-azul.kp.local" \
  https://192.168.66.201/realms/azul
# Expected: 200

# OpenSearch cluster health
OS_ADMIN_PASS=$(grep OS_ADMIN_PASS /data/AZUL/.azul-credentials | cut -d= -f2)
kubectl exec azul-opensearch-nodes-0 -n azul-infra -- \
  curl -sf -u "admin:${OS_ADMIN_PASS}" -k https://localhost:9200/_cluster/health \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Status: {d[\"status\"]}, Nodes: {d[\"number_of_nodes\"]}')"
# Expected: Status: green, Nodes: 1
```

**Or use the script**: `/data/AZUL/scripts/azul-deploy.sh infra`

---

### Step 5: Redeploy Core Application (Stage 2)

#### 5a. Create Namespace and Secrets

> **CRITICAL**: Redis secret must have keys `redis-username`, `redis-password`, AND `password` (Issue #22). Missing `redis-username` causes `CreateContainerConfigError` on dispatcher pods.

```bash
kubectl create namespace azul

# Copy MinIO keys from infra
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

# Redis — MUST include redis-username and redis-password keys
REDIS_PASS=$(openssl rand -base64 16)
kubectl create secret generic redis -n azul \
  --from-literal=redis-username="" \
  --from-literal=redis-password="$REDIS_PASS" \
  --from-literal=password="$REDIS_PASS"

# Metastore writer credentials
# The writer password bcrypt hash MUST match azul-infra-values.yaml internal_users.azul_writer.hash
WRITER_PASS=$(openssl rand -base64 16)
kubectl create secret generic metastore-creds -n azul \
  --from-literal=writer="$WRITER_PASS"

# Generate bcrypt hash and update azul-infra-values.yaml
WRITER_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${WRITER_PASS}', bcrypt.gensalt()).decode())")
# Replace the hash line in azul-infra-values.yaml (there's only one bcrypt hash in the file)
sed -i "s|hash: \"\\\$2b\\\$.*\"|hash: \"${WRITER_HASH}\"|" /data/AZUL/azul-infra-values.yaml

# Apply the updated hash to OpenSearch
helm upgrade azul-infra /data/AZUL/azul-app/infra \
  -n azul-infra -f /data/AZUL/azul-infra-values.yaml --timeout 5m

# Re-append Test CA (helm upgrade regenerated the configmap)
# (Repeat section 4h above)

# S3 backup keys
kubectl create secret generic s3-backup-keys -n azul \
  --from-literal=access_key="azul-backup" \
  --from-literal=secret_key="azul-backup-secret"

# CA cert configmap
kubectl create configmap azul-ca-cert -n azul \
  --from-file=ca.crt=/data/AZUL/opensearch-ca.crt
```

> **CRITICAL**: After creating `metastore-creds` with a new password, you MUST update the bcrypt hash in `azul-infra-values.yaml` and run `helm upgrade azul-infra`. Otherwise metastore pods will CrashLoop with "Authentication finally failed" on OpenSearch.

#### 5b. Create Web TLS Certificate

The web ingress references `azul-web-tls` secret. Without it, nginx serves a fake certificate (Issue #25):

```bash
# Copy CA secret to azul namespace
kubectl get secret azul-opensearch-ca-cert -n azul-infra -o json \
  | python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata'] = {'name': 'azul-opensearch-ca-cert', 'namespace': 'azul'}
print(json.dumps(s))
" | kubectl apply -f -

# Create namespace-scoped Issuer
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

# Create Certificate
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
```

#### 5c. Deploy Core App

```bash
# Use azul-values-core.yaml (pluginsEnabled: false) for Stage 2
helm install azul /data/AZUL/azul-app/azul \
  -n azul -f /data/AZUL/azul-values-core.yaml --timeout 10m
```

#### 5d. Wait for Core Pods (13 expected)

```bash
# Wait for all pods
kubectl wait --for=condition=ready pods --all -n azul --timeout=300s

# Verify: 13 pods (redis, docs, 5 dispatchers, 4 metastores, restapi, webui)
kubectl get pods -n azul
```

> **NOTE**: Metastore pods may CrashLoop 2-3 times on first startup while dispatchers initialise Kafka connections. This is normal and self-resolves within ~2 minutes.

#### 5e. Verify Stage 2

```bash
# Web UI
curl -k -s -o /dev/null -w "%{http_code}\n" -H "Host: azul.kp.local" https://192.168.66.201/
# Expected: 302

# OAuth token for test user
TOKEN=$(curl -k -s -X POST "https://keycloak-azul.kp.local/realms/azul/protocol/openid-connect/token" \
  --resolve "keycloak-azul.kp.local:443:192.168.66.201" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=basic&password=basic12345&grant_type=password&client_id=azul-web' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

# API /users/me with token
curl -k -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: azul.kp.local" \
  -H "Authorization: Bearer $TOKEN" \
  "https://192.168.66.201/api/v0/users/me"
# Expected: 200
```

**Or use the script**: `/data/AZUL/scripts/azul-deploy.sh app`

---

### Step 6: Redeploy Plugins (Stage 3)

#### 6a. Upgrade with Full Values

```bash
# Use azul-values.yaml (pluginsEnabled: true)
helm upgrade azul /data/AZUL/azul-app/azul \
  -n azul -f /data/AZUL/azul-values.yaml --timeout 10m
```

#### 6b. Scale-to-Zero/One (LimitRange CPU Workaround)

New plugin pods may inherit stale LimitRange defaults. Scale to 0 then 1 to force recreation:

```bash
# Get all plugin deployment names
PLUGINS=$(kubectl get deployments -n azul --no-headers -o custom-columns=NAME:.metadata.name \
  | grep -E "^(office-|tika|alphabets|android|build-time|mandiant|certificates|debloat|de4dot|dotnet|email|entropy|entrypoint|exiftool|export-hash|floss|ghidra|goinfo|image-convert|index-|js-deobf|lief-|lookback-|malcarve|netinfo|pdftools-|portex|qrcode|python|repeated|richid|script-decoder|shortcut|unbox)")

# Scale to 0
echo "$PLUGINS" | xargs -I{} kubectl scale deployment {} -n azul --replicas=0

# Wait for termination
sleep 30

# Scale to 1
echo "$PLUGINS" | xargs -I{} kubectl scale deployment {} -n azul --replicas=1
```

#### 6c. Wait and Verify

```bash
# Wait for images to pull and pods to start (may take 5-10 minutes)
kubectl get pods -n azul --watch

# Count pods
kubectl get pods -n azul --no-headers | wc -l
# Expected: ~63 (62-63 depending on ghidra CPU availability)

# Check for CrashLoopBackOff
kubectl get pods -n azul --no-headers | grep CrashLoopBackOff
# Expected: none

# Check for Pending
kubectl get pods -n azul --no-headers | grep Pending
# Expected: possibly ghidra (requests 500m CPU, may not fit on packed cluster)
```

**Or use the script**: `/data/AZUL/scripts/azul-deploy.sh plugins`

---

### Step 7: Restore from Backup

#### 7a. Pre-flight Checks

```bash
# External MinIO must be running
curl -sf http://localhost:9100/minio/health/live && echo "MinIO: OK"

# Backup data must exist
du -sh /data/backups/azul-minio/azul-backup-01-streams
du -sh /data/backups/azul-minio/azul-backup-01-events

# s3-backup-keys secret must exist
kubectl get secret s3-backup-keys -n azul
```

#### 7b. Run Restore

```bash
# Set recovery.mode to "restore"
sed -i 's/^  mode: .*/  mode: "restore"/' /data/AZUL/azul-values.yaml

# Deploy restore Job
helm upgrade azul /data/AZUL/azul-app/azul -n azul -f /data/AZUL/azul-values.yaml --timeout 5m

# Monitor the restore Job
kubectl get jobs -n azul | grep restore
kubectl logs -n azul -l "app.kubernetes.io/component=recovery-restore" -f

# Wait for completion
kubectl wait --for=condition=complete job -l "app.kubernetes.io/component=recovery-restore" \
  -n azul --timeout=1800s
```

#### 7c. Reset Recovery Mode

```bash
# Set mode back to "off"
sed -i 's/^  mode: .*/  mode: "off"/' /data/AZUL/azul-values.yaml
helm upgrade azul /data/AZUL/azul-app/azul -n azul -f /data/AZUL/azul-values.yaml --timeout 5m
```

**Or use the script**: `/data/AZUL/scripts/azul-restore.sh` (or `--check` to verify backup status first)

---

### Lifecycle Test Results (2026-02-12)

| Step | Result | Details |
|------|--------|---------|
| 1. Backup | PASS | 30MB backed up (2.8MB events, 27MB streams), Keycloak export 57KB |
| 2. Teardown | PASS | All 4 namespaces removed, 10 Strimzi CRDs + OpenSearch CRDs deleted |
| 3. Validate | PASS | No azul namespaces, no CRDs, no helm releases, MinIO data intact |
| 4. Infra redeploy | PASS | All pods running, Keycloak 200, OpenSearch green |
| 5. Core redeploy | PASS | 13/13 pods, Web UI 302, OAuth OK, API /users/me 200 |
| 6. Plugins redeploy | PASS | 62/63 pods (ghidra Pending — 500m CPU, known limitation) |
| 7. Restore | PASS | 3,318 events + 419 streams restored at 194 events/s |

### Known Gotchas

1. **Writer password sync**: When creating a fresh `metastore-creds` secret, the bcrypt hash in `azul-infra-values.yaml` must be updated and `helm upgrade azul-infra` must be run. The deploy script handles this automatically.

2. **Test CA re-append**: Every `helm upgrade azul-infra` regenerates the `azul-opensearch-certs` configmap from the chart's bundled `ca-certificates` file, losing the appended Test CA. Must re-append after every infra upgrade. Use `--server-side --field-manager=helm --force-conflicts` to avoid field manager conflicts.

3. **Keycloak setup-keycloak.sh timeout**: The script's `kubectl port-forward` may time out at 2 minutes. If it doesn't complete all steps, manually finish via the Keycloak Admin Console.

4. **Ghidra CPU**: The ghidra plugin requests 500m CPU which may not be available on a fully packed cluster. It will show as Pending. This is acceptable — it will schedule when resources become available.

5. **Metastore initial CrashLoop**: On first deploy, metastore pods CrashLoop 2-3 times while dispatchers initialise Kafka topic connections. This self-resolves within ~2 minutes.

6. **OpenSearch unsafe-bootstrap**: Always needed for single-node clusters after fresh deploy. The deploy script detects this automatically.

7. **Web TLS certificate**: The `azul-web-tls` secret must be created manually (or by the deploy script). The Helm chart references it but doesn't create it. Without it, nginx serves a fake certificate.

8. **Pi-hole DNS records**: All `*.kp.local` Azul hostnames must be in Pi-hole. The browser OIDC flow redirects to `keycloak-azul.kp.local` — if DNS doesn't resolve, login fails silently.

9. **OIDC scopes must be exact**: For Keycloak, use `openid profile offline_access roles azul`. Without `offline_access`, sessions can't refresh tokens. Without `roles`, role-based access won't work. The official Azul docs warn: "If Azul continually refreshes without loading, verify scopes match the documented configuration."

10. **Keycloak audience mapper required**: The `audience` client scope must include an `oidc-audience-mapper` with `included.client.audience: azul-web`. Without it, access tokens have `aud: "account"` and the REST API rejects them as "Invalid audience".

11. **helm upgrade azul-infra strips Test CA**: `helm upgrade azul-infra` regenerates the `azul-opensearch-certs` configmap from the chart's bundled CA bundle, stripping the appended Test CA. The OpenSearch operator may also reconcile it back during pod restarts. The deploy, backup, and restore scripts all include `reapply_test_ca()` to re-append after helm upgrades. If running helm upgrade manually, always check and re-append the Test CA afterward.

12. **OpenSearch unsafe-bootstrap after every restart**: Single-node OpenSearch requires unsafe-bootstrap after EVERY pod restart (not just initial deploy). The node ID changes on each restart, invalidating the voting config. The deploy script's `run_opensearch_bootstrap` handles this automatically.

---

## Offline Install Checklist

For a fully offline installation, gather these before disconnecting from the internet:

### Pre-staging (with internet)

1. [ ] Clone repo: `git clone https://github.com/AustralianCyberSecurityCentre/azul-app.git`
2. [ ] Checkout stable app tag: `cd azul-app && git checkout azul-9.0.0` (for app chart; infra chart uses main branch)
3. [ ] Pull Helm charts: `helm pull strimzi/strimzi-kafka-operator --version 0.50.0` and `helm pull opensearch-operator/opensearch-operator --version 2.8.0`
4. [ ] Pull all container images listed in "Container Images Required" section:
   - Infrastructure images (7): MinIO, Keycloak, Postgres, Kafkactl, OpenSearch, OpenSearch Dashboards, busybox
   - Kafka images (2): Strimzi Kafka builds
   - Operator images (3): Strimzi operator, OpenSearch operator, kube-rbac-proxy
   - App core images (7): dispatcher, restapi-server, webui, docs, client, backup, redis
   - **Plugin images (37)**: 34 asdazul plugin images + apache/tika + git-sync + redis (see image pull script above)
5. [ ] Copy custom files to offline media:
   - `azul-infra-values.yaml` — infrastructure overrides
   - `azul-values.yaml` — app + plugin overrides (pluginsEnabled: true, Stage 3)
   - `azul-values-core.yaml` — app core-only overrides (pluginsEnabled: false, Stage 2)
   - `setup-keycloak.sh` — Keycloak realm/client/user setup (includes sub mapper fix)
   - `.azul-credentials` — pre-generated secrets
   - `docker-compose-backup.yaml` — external MinIO for backup
   - `scripts/azul-backup.sh`, `azul-teardown.sh`, `azul-deploy.sh`, `azul-restore.sh`
   - Template patches (sections 1.6.1-1.6.3)
6. [ ] Export CA certificate (or generate new self-signed on target)

### Installation (offline)

7. [ ] Load all container images into target registry or nodes
8. [ ] Configure Pi-hole DNS records (see DNS Records section)
9. [ ] Apply template patches to cloned repo (sections 1.6.1-1.6.3)
10. [ ] Install using deploy script (recommended) or manual steps:
    - **Scripted**: `/data/AZUL/scripts/azul-deploy.sh all` (performs all steps below automatically)
    - **Manual**:
      1. Operators: Strimzi + OpenSearch operator
      2. Secrets: Create all K8s secrets in azul-infra namespace
      3. `helm install azul-infra` with `azul-infra-values.yaml`
      4. CoreDNS configmap patch for `*.kp.local` resolution
      5. Keycloak TLS cert (cert-manager)
      6. Append Test CA to OpenSearch certs configmap (section 1.7.7)
      7. Restart OpenSearch pod
      8. Run `setup-keycloak.sh` (includes sub mapper for Keycloak 26.x)
      9. OpenSearch unsafe-bootstrap if needed
      10. Create secrets in azul namespace
      11. `helm install azul` with `azul-values-core.yaml` (Stage 2: core only, no plugins)
      12. Verify: Web UI loads, OIDC login works, API /users/me returns 200
      13. `helm upgrade azul` with `azul-values.yaml` (Stage 3: plugins enabled)
      14. Scale plugin deployments to 0 then back to 1 (LimitRange CPU workaround, Issue #18)

### Verification

11. [ ] `kubectl get pods -n azul` — 63 pods Running (13 core + 50 plugins)
12. [ ] Web UI loads at `https://azul.kp.local/`
13. [ ] Login works with test user (`basic / basic12345`)
14. [ ] Submit a test file — plugin results should appear within ~1 minute
