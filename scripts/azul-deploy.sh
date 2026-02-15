#!/usr/bin/env bash
# AZUL 3-Stage Deploy Script
# Deploys Azul to a clean Kubernetes cluster in three stages with
# health verification at each stage.
#
# Stages:
#   1. infra   - Operators + Infrastructure (Kafka, OpenSearch, MinIO, Keycloak, Postgres)
#   2. app     - Core application (dispatcher, restapi, webui, metastore, redis)
#   3. plugins - Analysis plugins (office, tika, generic, yara-x, suricata, maco)
#
# Prerequisites:
#   - Talos PodSecurity exemptions already applied (kafka, opensearch-operator, azul-infra, azul)
#   - Chart repo at /data/AZUL/azul-app/ already checked out (azul-9.0.0 tag)
#     and patched (keycloak port, opensearch additionalVolumes/additionalConfig)
#   - Helm repos added: strimzi, opensearch-operator
#   - Credentials file: /data/AZUL/.azul-credentials
#   - Values files: azul-infra-values.yaml, azul-values-core.yaml, azul-values.yaml
#
# Usage:
#   ./azul-deploy.sh all       # Deploy all 3 stages
#   ./azul-deploy.sh infra     # Stage 1 only
#   ./azul-deploy.sh app       # Stage 2 only
#   ./azul-deploy.sh plugins   # Stage 3 only
#
# Compatible with: Ubuntu 22.04+, RHEL 9+
set -euo pipefail

export KUBECONFIG="/home/kp-admin/KUBS/kubeconfig"

AZUL_DIR="/data/AZUL"
INFRA_VALUES="${AZUL_DIR}/azul-infra-values.yaml"
CORE_VALUES="${AZUL_DIR}/azul-values-core.yaml"
FULL_VALUES="${AZUL_DIR}/azul-values.yaml"
INFRA_CHART="${AZUL_DIR}/azul-app/infra"
APP_CHART="${AZUL_DIR}/azul-app/azul"
CREDS_FILE="${AZUL_DIR}/.azul-credentials"
KEYCLOAK_SCRIPT="${AZUL_DIR}/setup-keycloak.sh"

# Source certificate functions (patch_ca_into_chart, create_keycloak_cert, etc.)
source "${AZUL_DIR}/scripts/setup-certs.sh"

DISCORD_WEBHOOK="https://discord.com/api/webhooks/1469836076154884215/SRt_iwtFSJVveLipv2DZ0i6h5tCLhejiD2mlmLUCllPtSgl0CfnRQGxRvy1Lk5lPJDLJ"

# --- Helpers ---

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

die() { log "FATAL: $*"; send_discord "Deploy" "failed" "$*"; exit 1; }

send_discord() {
    local operation="$1" status="$2" details="${3:-}" color
    [ "$status" = "success" ] && color="65280" || color="16711680"
    curl -sf -H "Content-Type: application/json" -d "{
        \"embeds\": [{
            \"title\": \"Azul Deploy\",
            \"color\": $color,
            \"fields\": [
                {\"name\": \"Operation\", \"value\": \"$operation\", \"inline\": true},
                {\"name\": \"Status\", \"value\": \"$status\", \"inline\": true},
                {\"name\": \"Date\", \"value\": \"$(date '+%Y-%m-%d %H:%M:%S')\", \"inline\": false},
                {\"name\": \"Details\", \"value\": \"${details:-N/A}\", \"inline\": false}
            ]
        }]
    }" "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
}

# Load credentials from file
load_creds() {
    if [ ! -f "$CREDS_FILE" ]; then
        die "Credentials file not found: $CREDS_FILE"
    fi
    # Source the creds file (key=value format)
    while IFS='=' read -r key value; do
        case "$key" in
            S3_ACCESS_KEY) S3_ACCESS_KEY="$value" ;;
            S3_SECRET_KEY) S3_SECRET_KEY="$value" ;;
            OS_ADMIN_PASS) OS_ADMIN_PASS="$value" ;;
            OS_DASH_PASS) OS_DASH_PASS="$value" ;;
            KC_DB_PASSWORD) KC_DB_PASSWORD="$value" ;;
            KC_ADMIN_PASSWORD) KC_ADMIN_PASSWORD="$value" ;;
        esac
    done < <(grep -v '^#' "$CREDS_FILE" | grep -v '^$' | grep '=')
}

wait_for_pods() {
    local namespace="$1" timeout="${2:-300}" label="${3:-}"
    local selector=""
    [ -n "$label" ] && selector="-l $label"

    log "Waiting for pods in $namespace to be ready (timeout: ${timeout}s)..."
    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        local not_ready
        not_ready=$(kubectl get pods -n "$namespace" $selector --no-headers 2>/dev/null \
            | grep -v "Completed" \
            | grep -cvE "([0-9]+)/\1\s+Running" 2>/dev/null) || not_ready="0"
        if [ "$not_ready" = "0" ]; then
            local total
            total=$(kubectl get pods -n "$namespace" $selector --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
            if [ "$total" -gt 0 ]; then
                log "All $total pods ready in $namespace"
                return 0
            fi
        fi
        sleep 10
    done
    log "WARNING: Not all pods ready in $namespace after ${timeout}s"
    kubectl get pods -n "$namespace" $selector --no-headers 2>/dev/null | grep -v "Running\|Completed" || true
    return 1
}

# ===================================================================
# STAGE 1: INFRASTRUCTURE
# ===================================================================

stage_infra() {
    log "============================================"
    log "=== STAGE 1: INFRASTRUCTURE ==="
    log "============================================"

    # --- 1.1 Install Strimzi Kafka Operator ---
    log ""
    log "--- 1.1 Installing Strimzi Kafka Operator ---"
    if helm status strimzi-kafka-operator -n kafka >/dev/null 2>&1; then
        log "Strimzi already installed, skipping"
    else
        helm install strimzi-kafka-operator "${AZUL_DIR}/charts/strimzi-kafka-operator-helm-3-chart-0.50.0.tgz" \
            --namespace kafka --create-namespace \
            --set watchAnyNamespace=true \
            --timeout 3m
        log "Strimzi operator installed"
    fi

    # Wait for Strimzi operator
    kubectl wait --for=condition=ready pod -l name=strimzi-cluster-operator -n kafka --timeout=120s 2>/dev/null || true

    # --- 1.2 Install OpenSearch Operator ---
    log ""
    log "--- 1.2 Installing OpenSearch Operator ---"
    if helm status opensearch-operator -n opensearch-operator >/dev/null 2>&1; then
        log "OpenSearch operator already installed, skipping"
    else
        helm install opensearch-operator "${AZUL_DIR}/charts/opensearch-operator-2.8.0.tgz" \
            --namespace opensearch-operator --create-namespace \
            --timeout 3m
        log "OpenSearch operator installed"
    fi

    kubectl wait --for=condition=ready pod -l control-plane=controller-manager -n opensearch-operator --timeout=120s 2>/dev/null || true

    # --- 1.3 Create azul-infra namespace and secrets ---
    log ""
    log "--- 1.3 Creating azul-infra namespace and secrets ---"
    load_creds

    kubectl create namespace azul-infra 2>/dev/null || log "Namespace azul-infra already exists"

    # MinIO keys
    if ! kubectl get secret s3-keys -n azul-infra >/dev/null 2>&1; then
        kubectl create secret generic s3-keys -n azul-infra \
            --from-literal=accesskey="$S3_ACCESS_KEY" \
            --from-literal=secretkey="$S3_SECRET_KEY"
        log "Created secret: s3-keys"
    else
        log "Secret s3-keys already exists"
    fi

    # OpenSearch admin
    if ! kubectl get secret azul-cluster-admincredentials -n azul-infra >/dev/null 2>&1; then
        kubectl create secret generic azul-cluster-admincredentials -n azul-infra \
            --from-literal=username=admin \
            --from-literal=password="$OS_ADMIN_PASS"
        log "Created secret: azul-cluster-admincredentials"
    else
        log "Secret azul-cluster-admincredentials already exists"
    fi

    # OpenSearch dashboard
    if ! kubectl get secret azul-cluster-dashboardcredentials -n azul-infra >/dev/null 2>&1; then
        kubectl create secret generic azul-cluster-dashboardcredentials -n azul-infra \
            --from-literal=username=kibanaserver \
            --from-literal=password="$OS_DASH_PASS"
        log "Created secret: azul-cluster-dashboardcredentials"
    else
        log "Secret azul-cluster-dashboardcredentials already exists"
    fi

    # Keycloak
    if ! kubectl get secret keycloak -n azul-infra >/dev/null 2>&1; then
        kubectl create secret generic keycloak -n azul-infra \
            --from-literal=DB_PASSWORD="$KC_DB_PASSWORD" \
            --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD"
        log "Created secret: keycloak"
    else
        log "Secret keycloak already exists"
    fi

    # --- 1.4 Install azul-infra Helm chart ---
    log ""
    log "--- 1.4 Installing azul-infra Helm chart ---"
    if helm status azul-infra -n azul-infra >/dev/null 2>&1; then
        log "azul-infra already installed, running upgrade..."
        helm upgrade azul-infra "$INFRA_CHART" -n azul-infra -f "$INFRA_VALUES" --timeout 10m
    else
        helm install azul-infra "$INFRA_CHART" -n azul-infra -f "$INFRA_VALUES" --timeout 10m
    fi
    log "azul-infra chart deployed"

    # --- 1.4b Patch Test CA into chart bundle ---
    # cert-manager creates the CA during helm install. Patch it into the chart's
    # ca-certificates file so all future helm upgrades include it natively.
    wait_for_ca
    patch_ca_into_chart

    # --- 1.5 Wait for infra pods ---
    log ""
    log "--- 1.5 Waiting for infrastructure pods ---"
    # These come up gradually - Kafka first, then OpenSearch, then Keycloak
    log "Waiting for Kafka..."
    kubectl wait --for=condition=ready pod -l strimzi.io/component-type=kafka -n azul-infra --timeout=300s 2>/dev/null || true

    log "Waiting for MinIO..."
    kubectl wait --for=condition=ready pod -l app=minio -n azul-infra --timeout=180s 2>/dev/null || true

    log "Waiting for Postgres..."
    kubectl wait --for=condition=ready pod -l app=postgres -n azul-infra --timeout=180s 2>/dev/null || true

    log "Waiting for Keycloak..."
    kubectl wait --for=condition=ready pod -l app=keycloak -n azul-infra --timeout=300s 2>/dev/null || true

    # OpenSearch may need unsafe-bootstrap for single-node
    log "Waiting for OpenSearch (may need bootstrap fix)..."
    sleep 30

    # Check if OpenSearch is stuck
    local os_ready
    os_ready=$(kubectl get pod azul-opensearch-nodes-0 -n azul-infra -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$os_ready" != "True" ]; then
        log "OpenSearch not ready, attempting single-node unsafe-bootstrap..."
        run_opensearch_bootstrap
    fi

    kubectl wait --for=condition=ready pod/azul-opensearch-nodes-0 -n azul-infra --timeout=180s 2>/dev/null || true

    # --- 1.6 CoreDNS hosts block ---
    log ""
    log "--- 1.6 Configuring CoreDNS hosts ---"
    configure_coredns

    # --- 1.7 Keycloak TLS cert ---
    log ""
    log "--- 1.7 Creating Keycloak TLS certificate ---"
    create_keycloak_cert

    # --- 1.8 Bake Test CA into OpenSearch cert bundle ---
    log ""
    log "--- 1.8 Baking Test CA into OpenSearch cert bundle ---"
    bake_test_ca

    # --- 1.9 Run Keycloak setup ---
    log ""
    log "--- 1.9 Configuring Keycloak realm and users ---"
    if [ -f "$KEYCLOAK_SCRIPT" ]; then
        bash "$KEYCLOAK_SCRIPT"
        log "Keycloak configuration complete"
    else
        log "WARNING: Keycloak setup script not found at $KEYCLOAK_SCRIPT"
    fi

    # --- 1.10 Verify ---
    log ""
    log "--- 1.10 Verifying Stage 1 ---"
    verify_infra

    send_discord "Stage 1: Infrastructure" "success" "All infra pods running, Keycloak configured"
    log ""
    log "=== STAGE 1 COMPLETE ==="
}

run_opensearch_bootstrap() {
    log "Running OpenSearch single-node unsafe-bootstrap..."

    # Scale down operator
    kubectl scale deployment opensearch-operator-controller-manager \
        -n opensearch-operator --replicas=0 2>/dev/null || true
    sleep 5

    # Scale down OpenSearch
    kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=0 2>/dev/null || true
    sleep 15

    # Run unsafe-bootstrap job
    kubectl delete job opensearch-unsafe-bootstrap -n azul-infra 2>/dev/null || true
    cat <<'EOJOB' | kubectl apply -f -
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
EOJOB

    kubectl wait --for=condition=complete job/opensearch-unsafe-bootstrap \
        -n azul-infra --timeout=120s 2>/dev/null || log "WARNING: Bootstrap job may not have completed"

    kubectl delete job opensearch-unsafe-bootstrap -n azul-infra 2>/dev/null || true

    # Restore
    kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=1
    kubectl scale deployment opensearch-operator-controller-manager \
        -n opensearch-operator --replicas=1 2>/dev/null || true

    log "Waiting for OpenSearch to come back..."
    sleep 30
}

configure_coredns() {
    local COREFILE
    COREFILE=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null)

    if echo "$COREFILE" | grep -q "keycloak-azul.kp.local"; then
        log "CoreDNS already has azul hosts entries"
        return 0
    fi

    log "Adding azul hosts block to CoreDNS..."
    # Insert hosts block before the first 'forward' directive
    NEW_COREFILE=$(echo "$COREFILE" | python3 -c "
import sys
content = sys.stdin.read()
hosts_block = '''    hosts {
        192.168.66.201 keycloak-azul.kp.local
        192.168.66.201 opensearch-azul.kp.local
        192.168.66.201 azul.kp.local
        fallthrough
    }
'''
# Insert before 'forward' line
lines = content.split('\n')
result = []
inserted = False
for line in lines:
    if 'forward' in line and not inserted:
        result.append(hosts_block.rstrip())
        inserted = True
    result.append(line)
if not inserted:
    # Fallback: insert before closing brace
    result2 = []
    for line in reversed(result):
        if line.strip() == '}' and not inserted:
            result2.append(line)
            result2.append(hosts_block.rstrip())
            inserted = True
        else:
            result2.append(line)
    result = list(reversed(result2))
print('\n'.join(result), end='')
")

    kubectl create configmap coredns -n kube-system \
        --from-literal=Corefile="$NEW_COREFILE" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl rollout restart deployment coredns -n kube-system
    log "CoreDNS updated"
}

# create_keycloak_cert() is sourced from setup-certs.sh

bake_test_ca() {
    # Check if OpenSearch already has the Test CA in its cert bundle
    local has_test_ca
    has_test_ca=$(kubectl exec azul-opensearch-nodes-0 -n azul-infra -- \
        grep -c "Test CA" /usr/share/opensearch/config/certs/ca-certificates 2>/dev/null) || has_test_ca="0"

    if [ "$has_test_ca" -gt 0 ] 2>/dev/null; then
        log "Test CA already in OpenSearch cert bundle"
        return 0
    fi

    # Ensure chart file is patched (idempotent)
    patch_ca_into_chart

    # Helm upgrade to apply the patched bundle to the configmap
    log "Running helm upgrade azul-infra to bake Test CA into configmap..."
    helm upgrade azul-infra "$INFRA_CHART" -n azul-infra -f "$INFRA_VALUES" --timeout 5m
    log "azul-infra upgraded with Test CA in bundle"

    # OpenSearch needs restart to pick up the new configmap.
    # Single-node requires unsafe-bootstrap after every restart (node ID changes).
    log "Restarting OpenSearch to pick up updated CA bundle..."
    run_opensearch_bootstrap
    kubectl wait --for=condition=Ready pod/azul-opensearch-nodes-0 -n azul-infra --timeout=180s 2>/dev/null || true
}

verify_infra() {
    local errors=0

    # Check all pods
    log "Checking infra pods..."
    local not_ready
    not_ready=$(kubectl get pods -n azul-infra --no-headers 2>/dev/null \
        | grep -v "Completed" \
        | grep -cvE "([0-9]+)/\1\s+Running" 2>/dev/null) || not_ready="0"
    if [ "$not_ready" != "0" ]; then
        log "WARNING: $not_ready pods not ready in azul-infra"
        kubectl get pods -n azul-infra --no-headers | grep -v "Running\|Completed" || true
        errors=$((errors + 1))
    else
        log "All infra pods running"
    fi

    # Check Keycloak endpoint
    log "Checking Keycloak..."
    local kc_code
    kc_code=$(curl -k -sf -o /dev/null -w '%{http_code}' \
        -H "Host: keycloak-azul.kp.local" https://192.168.66.201/realms/azul 2>/dev/null || echo "000")
    if [ "$kc_code" = "200" ]; then
        log "Keycloak azul realm: OK ($kc_code)"
    else
        log "WARNING: Keycloak azul realm returned $kc_code"
        errors=$((errors + 1))
    fi

    # Check OpenSearch
    log "Checking OpenSearch..."
    local os_health
    os_health=$(kubectl exec azul-opensearch-nodes-0 -n azul-infra -- \
        curl -sf -u "admin:$OS_ADMIN_PASS" -k https://localhost:9200/_cluster/health 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
    if [ "$os_health" = "green" ] || [ "$os_health" = "yellow" ]; then
        log "OpenSearch cluster health: $os_health"
    else
        log "WARNING: OpenSearch cluster health: $os_health"
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        log "Stage 1 verification: $errors warnings"
    else
        log "Stage 1 verification: ALL PASSED"
    fi
    return 0
}

# ===================================================================
# STAGE 2: APPLICATION (Core only, no plugins)
# ===================================================================

stage_app() {
    log "============================================"
    log "=== STAGE 2: APPLICATION (Core) ==="
    log "============================================"

    load_creds

    # --- 2.1 Create azul namespace and secrets ---
    log ""
    log "--- 2.1 Creating azul namespace and secrets ---"
    kubectl create namespace azul 2>/dev/null || log "Namespace azul already exists"

    # Copy MinIO keys from infra
    if ! kubectl get secret s3-keys -n azul >/dev/null 2>&1; then
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
        log "Created secret: s3-keys (copied from azul-infra)"
    else
        log "Secret s3-keys already exists"
    fi

    # Redis password (chart expects redis-username, redis-password, AND password keys)
    if ! kubectl get secret redis -n azul >/dev/null 2>&1; then
        local redis_pass
        redis_pass=$(openssl rand -base64 16)
        kubectl create secret generic redis -n azul \
            --from-literal=redis-username="" \
            --from-literal=redis-password="$redis_pass" \
            --from-literal=password="$redis_pass"
        log "Created secret: redis (with redis-username, redis-password, password keys)"
    else
        log "Secret redis already exists"
    fi

    # Metastore credentials (OpenSearch writer)
    # The writer password must match the bcrypt hash in azul-infra-values.yaml internal_users.
    # If we create a new secret, we also update the infra values and helm upgrade azul-infra.
    if ! kubectl get secret metastore-creds -n azul >/dev/null 2>&1; then
        local writer_pass writer_hash
        writer_pass=$(openssl rand -base64 16)
        kubectl create secret generic metastore-creds -n azul \
            --from-literal=writer="$writer_pass"
        log "Created secret: metastore-creds"

        # Generate bcrypt hash and update azul-infra-values.yaml
        writer_hash=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${writer_pass}', bcrypt.gensalt()).decode())")
        log "Generated bcrypt hash for writer password"

        # Update the hash in azul-infra-values.yaml
        sed -i "s|hash: \"\\\$2b\\\$.*\"|hash: \"${writer_hash}\"|" "$INFRA_VALUES"
        log "Updated azul_writer bcrypt hash in $INFRA_VALUES"

        # Helm upgrade azul-infra to apply the new hash
        log "Running helm upgrade azul-infra to apply writer hash..."
        helm upgrade azul-infra "$INFRA_CHART" -n azul-infra -f "$INFRA_VALUES" --timeout 5m
        log "azul-infra upgraded with new writer hash"
        # Test CA is baked into the chart's ca-certificates file,
        # so helm upgrade preserves it automatically.
    else
        log "Secret metastore-creds already exists"
    fi

    # S3 backup keys (for recovery/backup feature — uses external MinIO on the host)
    if ! kubectl get secret s3-backup-keys -n azul >/dev/null 2>&1; then
        kubectl create secret generic s3-backup-keys -n azul \
            --from-literal=access_key="azul-backup" \
            --from-literal=secret_key="azul-backup-secret"
        log "Created secret: s3-backup-keys"
    else
        log "Secret s3-backup-keys already exists"
    fi

    # CA cert configmap (extracted directly from cluster secret)
    create_ca_configmap

    # Web TLS certificate (azul-web-tls)
    create_azul_web_cert

    # --- 2.2 Install azul chart (core only, no plugins) ---
    log ""
    log "--- 2.2 Installing azul chart (core only) ---"
    if helm status azul -n azul >/dev/null 2>&1; then
        log "azul already installed, running upgrade with core values..."
        helm upgrade azul "$APP_CHART" -n azul -f "$CORE_VALUES" --timeout 10m
    else
        helm install azul "$APP_CHART" -n azul -f "$CORE_VALUES" --timeout 10m
    fi
    log "azul chart deployed (core only, plugins disabled)"

    # --- 2.3 Wait for core pods ---
    log ""
    log "--- 2.3 Waiting for core pods ---"
    # Core pods: redis, docs, 5x dispatchers, 4x metastores, restapi, webui = 13
    wait_for_pods "azul" 300 || true

    # --- 2.4 Verify ---
    log ""
    log "--- 2.4 Verifying Stage 2 ---"
    verify_app

    send_discord "Stage 2: Application" "success" "Core pods running, Web UI accessible, API authenticated"
    log ""
    log "=== STAGE 2 COMPLETE ==="
}

verify_app() {
    local errors=0

    # Check pods
    log "Checking core pods..."
    local total
    total=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -c "Running") || total="0"
    local expected=13
    if [ "$total" -ge "$expected" ]; then
        log "Core pods: $total running (expected >= $expected)"
    else
        log "WARNING: Only $total pods running (expected >= $expected)"
        kubectl get pods -n azul --no-headers | grep -v "Running\|Completed" || true
        errors=$((errors + 1))
    fi

    # Check Web UI
    log "Checking Web UI..."
    local web_code
    web_code=$(curl -k -sf -o /dev/null -w '%{http_code}' \
        -H "Host: azul.kp.local" https://192.168.66.201/ 2>/dev/null || echo "000")
    if [ "$web_code" = "200" ] || [ "$web_code" = "302" ] || [ "$web_code" = "301" ]; then
        log "Web UI: OK ($web_code)"
    else
        log "WARNING: Web UI returned $web_code"
        errors=$((errors + 1))
    fi

    # Test OIDC authentication
    log "Testing OIDC authentication..."
    local token
    token=$(curl -k -sf -X POST \
        "https://keycloak-azul.kp.local/realms/azul/protocol/openid-connect/token" \
        --resolve "keycloak-azul.kp.local:443:192.168.66.201" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d 'username=basic&password=basic12345&grant_type=password&client_id=azul-web' \
        2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

    if [ -n "$token" ]; then
        log "OAuth token obtained for test user 'basic'"

        # Test API with token
        local api_code
        api_code=$(curl -k -sf -o /dev/null -w '%{http_code}' \
            -H "Host: azul.kp.local" \
            -H "Authorization: Bearer $token" \
            "https://192.168.66.201/api/v0/users/me" 2>/dev/null || echo "000")

        if [ "$api_code" = "200" ]; then
            log "API /users/me: OK ($api_code)"
        else
            log "WARNING: API /users/me returned $api_code"
            errors=$((errors + 1))
        fi
    else
        log "WARNING: Failed to obtain OAuth token"
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        log "Stage 2 verification: $errors warnings"
    else
        log "Stage 2 verification: ALL PASSED"
    fi
    return 0
}

# ===================================================================
# STAGE 3: PLUGINS
# ===================================================================

stage_plugins() {
    log "============================================"
    log "=== STAGE 3: PLUGINS ==="
    log "============================================"

    # --- 3.1 Helm upgrade with full values (plugins enabled) ---
    log ""
    log "--- 3.1 Upgrading azul with plugins enabled ---"
    if ! helm status azul -n azul >/dev/null 2>&1; then
        die "azul release not found. Run Stage 2 first."
    fi

    helm upgrade azul "$APP_CHART" -n azul -f "$FULL_VALUES" --timeout 10m
    log "azul chart upgraded with plugins enabled"

    # --- 3.2 Scale-to-zero/one workaround for LimitRange CPU ---
    log ""
    log "--- 3.2 Applying LimitRange CPU workaround (scale-to-zero/one) ---"
    # New plugin deployments may pick up old LimitRange defaults if they were
    # created before the LimitRange update. Scale-to-zero then back to 1 forces
    # pods to be recreated with the current LimitRange defaults.
    sleep 15  # Let deployments be created first

    local plugin_deployments
    plugin_deployments=$(kubectl get deployments -n azul --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
        | grep -E "^plugin-" || true)

    if [ -n "$plugin_deployments" ]; then
        log "Scaling plugin deployments to 0..."
        echo "$plugin_deployments" | while read -r deploy; do
            kubectl scale deployment "$deploy" -n azul --replicas=0 2>/dev/null || true
        done

        # Wait for all to terminate
        sleep 20
        log "Waiting for plugin pods to terminate..."
        local attempts=0
        while [ $attempts -lt 30 ]; do
            local running
            running=$(echo "$plugin_deployments" | while read -r deploy; do
                kubectl get pods -n azul -l "app.kubernetes.io/name=$deploy" --no-headers 2>/dev/null
            done | wc -l)
            if [ "$running" -eq 0 ]; then break; fi
            sleep 5
            attempts=$((attempts + 1))
        done

        log "Scaling plugin deployments to 1..."
        echo "$plugin_deployments" | while read -r deploy; do
            kubectl scale deployment "$deploy" -n azul --replicas=1 2>/dev/null || true
        done
    else
        log "No plugin deployments found to scale (they may not use this naming pattern)"
    fi

    # --- 3.3 Wait for all pods ---
    log ""
    log "--- 3.3 Waiting for all pods (core + plugins) ---"
    wait_for_pods "azul" 600 || true

    # --- 3.4 Verify ---
    log ""
    log "--- 3.4 Verifying Stage 3 ---"
    verify_plugins

    send_discord "Stage 3: Plugins" "success" "All pods running (core + plugins)"
    log ""
    log "=== STAGE 3 COMPLETE ==="
}

verify_plugins() {
    local errors=0

    # Count all pods
    local total running crashloop
    total=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
    running=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -c "Running") || running="0"
    crashloop=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -c "CrashLoopBackOff") || crashloop="0"

    log "Total pods: $total"
    log "Running: $running"
    log "CrashLoopBackOff: $crashloop"

    if [ "$crashloop" -gt 0 ]; then
        log "WARNING: $crashloop pods in CrashLoopBackOff:"
        kubectl get pods -n azul --no-headers | grep "CrashLoopBackOff" || true
        errors=$((errors + 1))
    fi

    local not_ready
    not_ready=$(kubectl get pods -n azul --no-headers 2>/dev/null \
        | grep -v "Completed" \
        | grep -cvE "([0-9]+)/\1\s+Running" 2>/dev/null) || not_ready="0"
    if [ "$not_ready" -gt 0 ]; then
        log "WARNING: $not_ready pods not fully ready"
        errors=$((errors + 1))
    fi

    if [ "$total" -ge 50 ]; then
        log "Pod count looks good (>= 50 expected with plugins)"
    else
        log "WARNING: Only $total pods (expected >= 50 with plugins)"
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        log "Stage 3 verification: $errors warnings"
    else
        log "Stage 3 verification: ALL PASSED"
    fi
    return 0
}

# ===================================================================
# MAIN
# ===================================================================

ACTION="${1:-}"

case "$ACTION" in
    infra)
        stage_infra
        ;;
    app)
        stage_app
        ;;
    plugins)
        stage_plugins
        ;;
    all)
        stage_infra
        log ""
        log "=========================================="
        log "Stage 1 complete. Starting Stage 2..."
        log "=========================================="
        log ""
        stage_app
        log ""
        log "=========================================="
        log "Stage 2 complete. Starting Stage 3..."
        log "=========================================="
        log ""
        stage_plugins
        log ""
        log "============================================"
        log "=== ALL 3 STAGES COMPLETE ==="
        log "============================================"
        log ""
        log "Azul is fully deployed."
        log "  Web UI: https://azul.kp.local"
        log "  Keycloak: https://keycloak-azul.kp.local"
        log "  OpenSearch: https://opensearch-azul.kp.local"
        log "  Test user: basic / basic12345"
        log "  Admin user: azuladmin / admin12345"
        log ""
        kubectl get pods -n azul --no-headers | wc -l | xargs -I{} log "Total pods in azul namespace: {}"
        send_discord "Full Deploy (3 stages)" "success" "All stages complete, Azul fully operational"
        ;;
    *)
        echo "Usage: $0 {all|infra|app|plugins}"
        echo ""
        echo "Stages:"
        echo "  infra   - Stage 1: Operators + Infrastructure (Kafka, OpenSearch, MinIO, Keycloak)"
        echo "  app     - Stage 2: Core application (dispatcher, restapi, webui, metastore, redis)"
        echo "  plugins - Stage 3: Analysis plugins (50 pods)"
        echo "  all     - All 3 stages in sequence"
        exit 1
        ;;
esac
