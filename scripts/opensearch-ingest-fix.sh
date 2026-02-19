#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# opensearch-ingest-fix.sh — Fix OpenSearch single-node bootstrap + security
#                            initialization + restart crashed metastore pods
#
# Problem: Single-node OpenSearch loses quorum after every pod restart because
#          the node ID changes, invalidating the voting configuration. This
#          causes "cluster_manager_not_discovered_exception" and the pod stays
#          0/1 Running. Additionally, unsafe-bootstrap wipes the
#          .opendistro_security index, requiring securityadmin.sh re-run.
#          Downstream, metastore pods fail with:
#            "503 OpenSearch Security not initialized"
#
# Root cause details:
#   - The azul-opensearch service routes to bootstrap-0 (not nodes-0) because
#     nodes-0 is not Ready. securityadmin.sh connecting via the service
#     times out with H2StreamResetException.
#   - Fix: run securityadmin.sh directly against nodes-0 pod IP.
#   - The bcrypt hashes in internal_users.yml (from the chart) may not match
#     the actual passwords in the K8s secrets. Fix: regenerate hashes from
#     the actual secret values and push via securityadmin.sh.
#
# What this script does:
#   1. Scales down OpenSearch operator + StatefulSet
#   2. Runs unsafe-bootstrap Job on the OpenSearch PVC
#   3. Scales everything back up
#   4. Waits for OpenSearch pod to be Running (not Ready — security not yet init)
#   5. Runs securityadmin.sh directly against nodes-0 pod IP to init security
#   6. Updates internal_users with correct password hashes from K8s secrets
#   7. Waits for nodes-0 to become Ready (readiness probe passes)
#   8. Restarts crashed metastore pods in azul namespace
#
# Usage:
#   ./opensearch-ingest-fix.sh          # Full fix (bootstrap + security + restart)
#   ./opensearch-ingest-fix.sh --check  # Just check current state
#   ./opensearch-ingest-fix.sh --security-only  # Skip bootstrap, just fix security
#
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# Source central config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AZUL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${AZUL_DIR}/azul.conf"
FILESERVER="${SERVICE_IP}:${FILESERVER_PORT}"
REGISTRY="${SERVICE_IP}:${REGISTRY_PORT}"

# Pre-flight: ensure python3 bcrypt module is available (RHEL 9 doesn't ship it)
if ! python3 -c "import bcrypt" >/dev/null 2>&1; then
    echo "[WARN] Python bcrypt module not found. Attempting pip install..."
    python3 -m pip install --quiet bcrypt 2>/dev/null || \
    python3 -m pip install --quiet --user bcrypt 2>/dev/null || \
    { echo "[FATAL] Cannot install bcrypt. Run: dnf install python3-bcrypt (RHEL) or apt install python3-bcrypt (Ubuntu)"; exit 1; }
fi

# Must match opensearch.general.version in azul-infra-values.yaml
OPENSEARCH_IMAGE="docker.io/opensearchproject/opensearch:3.2.0"
CREDS_FILE="${AZUL_DIR}/.azul-credentials"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "FATAL: $*"; exit 1; }

# ── Check current state ───────────────────────────────────────────────────
cmd_check() {
    log "=== OpenSearch & Metastore Status ==="
    log ""

    # OpenSearch node
    local os_ready
    os_ready=$(kubectl get pod azul-opensearch-nodes-0 -n azul-infra \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NotFound")
    local os_phase
    os_phase=$(kubectl get pod azul-opensearch-nodes-0 -n azul-infra \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    log "OpenSearch nodes-0: phase=$os_phase ready=$os_ready"

    # Bootstrap pod
    local bootstrap
    bootstrap=$(kubectl get pod azul-opensearch-bootstrap-0 -n azul-infra \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    log "OpenSearch bootstrap-0: $bootstrap"

    # Dashboards
    local dash_ready
    dash_ready=$(kubectl get pods -n azul-infra -l app=azul-opensearch-dashboards \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NotFound")
    log "OpenSearch dashboards: ready=$dash_ready"

    # Security config pod
    local secconfig
    secconfig=$(kubectl get pods -n azul-infra --no-headers 2>/dev/null \
        | grep "securityconfig" || echo "  (none)")
    log "Security config pods: $secconfig"

    # Service endpoints
    log ""
    local os_ep
    os_ep=$(kubectl get endpoints azul-opensearch -n azul-infra -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "none")
    log "azul-opensearch service endpoints: $os_ep"
    local nodes_ep
    nodes_ep=$(kubectl get endpoints azul-opensearch-nodes -n azul-infra -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "none")
    log "azul-opensearch-nodes service endpoints: $nodes_ep"

    # Test OpenSearch health
    if [ "$os_ready" = "True" ]; then
        local os_pass=""
        if [ -f "$CREDS_FILE" ]; then
            os_pass=$(grep "^OS_ADMIN_PASS=" "$CREDS_FILE" | cut -d= -f2-)
        fi
        if [ -n "$os_pass" ]; then
            local health
            health=$(kubectl exec azul-opensearch-nodes-0 -n azul-infra -- \
                curl -sf -u "admin:${os_pass}" -k https://localhost:9200/_cluster/health 2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'status={d[\"status\"]} nodes={d[\"number_of_nodes\"]}')" 2>/dev/null || echo "unreachable")
            log "OpenSearch health: $health"
        fi
    else
        # Try unauthenticated to see if security is the issue
        local unauth
        unauth=$(kubectl exec azul-opensearch-nodes-0 -n azul-infra -- \
            curl -sk https://localhost:9200 2>/dev/null || echo "unreachable")
        log "OpenSearch (unauthenticated): $unauth"
    fi

    # Metastore pods
    log ""
    log "Metastore pods in azul namespace:"
    kubectl get pods -n azul --no-headers 2>/dev/null | grep -E "^ms-" || log "  (none found)"

    log ""
    log "Non-running pods in azul:"
    kubectl get pods -n azul --no-headers 2>/dev/null | grep -v "Running\|Completed" || log "  (all running)"
}

# ── Run unsafe-bootstrap ─────────────────────────────────────────────────
run_bootstrap() {
    log "=== OpenSearch Unsafe-Bootstrap ==="

    # Check if already ready
    local os_ready
    os_ready=$(kubectl get pod azul-opensearch-nodes-0 -n azul-infra \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

    if [ "$os_ready" = "True" ]; then
        log "OpenSearch already Ready — skipping bootstrap"
        return 0
    fi

    log "OpenSearch not ready (ready=$os_ready), running unsafe-bootstrap..."

    # 1. Scale down operator
    log "  [1/6] Scaling down opensearch-operator..."
    kubectl scale deployment opensearch-operator-controller-manager \
        -n opensearch-operator --replicas=0 2>/dev/null || true
    sleep 5

    # 2. Scale down OpenSearch StatefulSet
    log "  [2/6] Scaling down azul-opensearch-nodes..."
    kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=0 2>/dev/null || true

    # Wait for pod to terminate
    log "  Waiting for pod to terminate..."
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if ! kubectl get pod azul-opensearch-nodes-0 -n azul-infra >/dev/null 2>&1; then
            break
        fi
        sleep 5
        attempts=$((attempts + 1))
    done

    # 3. Run bootstrap Job
    log "  [3/6] Running unsafe-bootstrap Job..."
    kubectl delete job opensearch-unsafe-bootstrap -n azul-infra 2>/dev/null || true

    cat <<EOJOB | kubectl apply -f -
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
        image: ${OPENSEARCH_IMAGE}
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

    # 4. Wait for Job
    log "  [4/6] Waiting for bootstrap Job to complete..."
    kubectl wait --for=condition=complete job/opensearch-unsafe-bootstrap \
        -n azul-infra --timeout=120s 2>/dev/null \
        && log "  Bootstrap Job: COMPLETED" \
        || log "  WARNING: Bootstrap Job may not have completed"

    kubectl delete job opensearch-unsafe-bootstrap -n azul-infra 2>/dev/null || true

    # 5. Scale back up
    log "  [5/6] Scaling up azul-opensearch-nodes..."
    kubectl scale statefulset azul-opensearch-nodes -n azul-infra --replicas=1

    log "  [6/6] Scaling up opensearch-operator..."
    kubectl scale deployment opensearch-operator-controller-manager \
        -n opensearch-operator --replicas=1 2>/dev/null || true

    # Wait for pod to be Running (NOT Ready — security not yet initialized)
    log "  Waiting for OpenSearch pod to be Running..."
    sleep 15
    local wait_attempts=0
    while [ $wait_attempts -lt 36 ]; do  # 3 minutes
        local phase
        phase=$(kubectl get pod azul-opensearch-nodes-0 -n azul-infra \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$phase" = "Running" ]; then
            log "  OpenSearch pod is Running (security init pending)"
            break
        fi
        sleep 5
        wait_attempts=$((wait_attempts + 1))
    done

    if [ $wait_attempts -ge 36 ]; then
        die "OpenSearch pod failed to reach Running state within 3 minutes"
    fi

    # Wait a bit more for OpenSearch to finish starting up internally
    log "  Waiting 30s for OpenSearch to fully start internally..."
    sleep 30
}

# ── Initialize security directly against nodes-0 ────────────────────────
init_security() {
    log ""
    log "=== Initializing OpenSearch Security ==="

    # Check if security is already initialized
    local os_pass=""
    if [ -f "$CREDS_FILE" ]; then
        os_pass=$(grep "^OS_ADMIN_PASS=" "$CREDS_FILE" | cut -d= -f2-)
    fi

    if [ -n "$os_pass" ]; then
        local health
        health=$(kubectl exec azul-opensearch-nodes-0 -n azul-infra -- \
            curl -sf -u "admin:${os_pass}" -k https://localhost:9200/_cluster/health 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
        if [ "$health" = "green" ] || [ "$health" = "yellow" ]; then
            log "Security already initialized, cluster health: $health"
            return 0
        fi
    fi

    log "Security not yet initialized, running securityadmin.sh..."

    # Get nodes-0 pod IP (MUST use pod IP, not service — service routes to bootstrap-0)
    local nodes_ip
    nodes_ip=$(kubectl get pod azul-opensearch-nodes-0 -n azul-infra \
        -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")

    if [ -z "$nodes_ip" ]; then
        die "Cannot determine nodes-0 pod IP"
    fi
    log "  nodes-0 pod IP: $nodes_ip"

    # Find the securityconfig-update pod (or any pod with the admin certs)
    local sec_pod
    sec_pod=$(kubectl get pods -n azul-infra --no-headers 2>/dev/null \
        | grep "securityconfig-update" | awk '{print $1}' | head -1 || true)

    if [ -z "$sec_pod" ]; then
        log "  No securityconfig-update pod found, creating temporary admin pod..."
        kubectl delete pod os-security-init -n azul-infra 2>/dev/null || true
        kubectl run os-security-init -n azul-infra \
            --image="${OPENSEARCH_IMAGE}" \
            --restart=Never \
            --overrides='{
                "spec": {
                    "containers": [{
                        "name": "os-security-init",
                        "image": "'"${OPENSEARCH_IMAGE}"'",
                        "command": ["sleep", "600"],
                        "volumeMounts": [{
                            "name": "admin-certs",
                            "mountPath": "/certs",
                            "readOnly": true
                        }]
                    }],
                    "volumes": [{
                        "name": "admin-certs",
                        "secret": {
                            "secretName": "azul-opensearch-admin-certs"
                        }
                    }]
                }
            }' 2>/dev/null
        sleep 10
        kubectl wait --for=condition=ready pod/os-security-init -n azul-infra --timeout=60s 2>/dev/null || true
        sec_pod="os-security-init"
    fi

    log "  Using pod: $sec_pod"

    # Wait for OpenSearch to respond on HTTPS (even with "Security not initialized")
    log "  Waiting for OpenSearch HTTPS to respond on nodes-0..."
    local wait_attempts=0
    while [ $wait_attempts -lt 24 ]; do  # 2 minutes
        local http_code
        http_code=$(kubectl exec "$sec_pod" -n azul-infra -- \
            curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 \
            "https://${nodes_ip}:9200" 2>/dev/null || echo "000")
        if [ "$http_code" != "000" ]; then
            log "  OpenSearch responding (HTTP $http_code)"
            break
        fi
        sleep 5
        wait_attempts=$((wait_attempts + 1))
    done

    # Step 1: Run securityadmin.sh to create .opendistro_security index
    log "  [1/2] Running securityadmin.sh against nodes-0 ($nodes_ip)..."
    local sa_output
    sa_output=$(kubectl exec "$sec_pod" -n azul-infra -- timeout 90 \
        /usr/share/opensearch/plugins/opensearch-security/tools/securityadmin.sh \
        -cacert /certs/ca.crt -cert /certs/tls.crt -key /certs/tls.key \
        -cd /usr/share/opensearch/config/opensearch-security \
        -icl -nhnv \
        -h "$nodes_ip" -p 9200 \
        --accept-red-cluster 2>&1) || true

    if echo "$sa_output" | grep -q "Done with success"; then
        log "  securityadmin.sh: SUCCESS"
    else
        log "  securityadmin.sh output:"
        echo "$sa_output" | tail -10 | while read -r line; do log "    $line"; done
        die "securityadmin.sh failed to initialize security"
    fi

    # Step 2: Update internal_users with correct password hashes from K8s secrets
    log "  [2/2] Updating internal_users with correct password hashes..."

    # Get the actual passwords from K8s secrets
    local admin_pass
    admin_pass=$(kubectl get secret azul-opensearch-admin-password -n azul-infra \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
    local dash_pass
    dash_pass=$(grep "^OS_DASH_PASS=" "$CREDS_FILE" 2>/dev/null | cut -d= -f2- || echo "")
    local writer_pass
    writer_pass=$(kubectl get secret metastore-creds -n azul \
        -o jsonpath='{.data.writer}' 2>/dev/null | base64 -d || echo "")

    if [ -z "$admin_pass" ]; then
        log "  WARNING: Cannot read admin password from secret, skipping hash update"
        log "  The readiness probe may fail if hashes don't match"
    else
        # Generate bcrypt hashes
        local admin_hash dash_hash writer_hash
        admin_hash=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${admin_pass}', bcrypt.gensalt(rounds=12)).decode())")

        if [ -n "$dash_pass" ]; then
            dash_hash=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${dash_pass}', bcrypt.gensalt(rounds=12)).decode())")
        else
            dash_hash="$admin_hash"
        fi

        if [ -n "$writer_pass" ]; then
            writer_hash=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${writer_pass}', bcrypt.gensalt(rounds=12)).decode())")
        else
            writer_hash="$admin_hash"
        fi

        # Write updated internal_users.yml into the pod
        kubectl exec "$sec_pod" -n azul-infra -- bash -c "cat > /tmp/internal_users.yml << 'EOIU'
_meta:
  config_version: 2
  type: internalusers
admin:
  backend_roles:
  - admin
  description: admin user
  hash: \"${admin_hash}\"
  reserved: true
azul_writer:
  backend_roles:
  - azul_write
  description: Service account for metastore writer
  hash: \"${writer_hash}\"
kibanaserver:
  hash: \"${dash_hash}\"
  reserved: true
monitor:
  description: Exporter monitoring
  hash: \"${admin_hash}\"
EOIU"

        # Push via securityadmin.sh
        local iu_output
        iu_output=$(kubectl exec "$sec_pod" -n azul-infra -- timeout 60 \
            /usr/share/opensearch/plugins/opensearch-security/tools/securityadmin.sh \
            -cacert /certs/ca.crt -cert /certs/tls.crt -key /certs/tls.key \
            -f /tmp/internal_users.yml -t internalusers \
            -icl -nhnv \
            -h "$nodes_ip" -p 9200 \
            --accept-red-cluster 2>&1) || true

        if echo "$iu_output" | grep -q "Done with success"; then
            log "  internal_users update: SUCCESS"
        else
            log "  WARNING: internal_users update may have failed"
            echo "$iu_output" | tail -5 | while read -r line; do log "    $line"; done
        fi
    fi

    # Clean up temporary pod if we created one
    if [ "$sec_pod" = "os-security-init" ]; then
        kubectl delete pod os-security-init -n azul-infra --grace-period=0 2>/dev/null || true
    fi

    # Wait for nodes-0 to become Ready (readiness probe should pass now)
    log ""
    log "  Waiting for nodes-0 to become Ready..."
    local ready_attempts=0
    while [ $ready_attempts -lt 12 ]; do  # 2 minutes
        local ready
        ready=$(kubectl get pod azul-opensearch-nodes-0 -n azul-infra \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$ready" = "True" ]; then
            log "  OpenSearch nodes-0: READY"
            return 0
        fi
        sleep 10
        ready_attempts=$((ready_attempts + 1))
    done

    die "OpenSearch nodes-0 failed to become Ready within 2 minutes after security init"
}

# ── Restart crashed metastore pods ────────────────────────────────────────
restart_metastore() {
    log ""
    log "=== Restarting Crashed Pods ==="

    # Check if azul namespace exists
    if ! kubectl get namespace azul >/dev/null 2>&1; then
        log "azul namespace not found — skipping"
        return 0
    fi

    # Find crashed/errored pods
    local crashed
    crashed=$(kubectl get pods -n azul --no-headers 2>/dev/null \
        | grep -E "CrashLoopBackOff|Error|ImagePullBackOff" \
        | awk '{print $1}') || true

    if [ -z "$crashed" ]; then
        log "No crashed pods found in azul namespace"
    else
        local count
        count=$(echo "$crashed" | wc -l)
        log "Found $count crashed pod(s), deleting to trigger restart:"
        echo "$crashed" | while read -r pod; do
            log "  Deleting $pod..."
            kubectl delete pod "$pod" -n azul --grace-period=0 2>/dev/null || true
        done
    fi

    # Also restart dashboards if it's crashing
    local dash_status
    dash_status=$(kubectl get pods -n azul-infra --no-headers 2>/dev/null \
        | grep "dashboards" | grep -E "CrashLoopBackOff|Error" || true)
    if [ -n "$dash_status" ]; then
        log "  Restarting OpenSearch Dashboards..."
        kubectl rollout restart deployment azul-opensearch-dashboards -n azul-infra 2>/dev/null || true
    fi

    # Wait for pods to recover
    log ""
    log "Waiting 30s for pods to recover..."
    sleep 30

    log ""
    log "=== Final Status ==="
    log ""
    log "azul-infra pods:"
    kubectl get pods -n azul-infra --no-headers 2>/dev/null | while read -r line; do log "  $line"; done

    log ""
    log "azul pods:"
    kubectl get pods -n azul --no-headers 2>/dev/null | while read -r line; do log "  $line"; done

    local still_crashed
    still_crashed=$(kubectl get pods -n azul --no-headers 2>/dev/null \
        | grep -E "CrashLoopBackOff|Error" | wc -l) || still_crashed="0"

    if [ "$still_crashed" -eq 0 ]; then
        log ""
        log "=== ALL PODS RECOVERED ==="
    else
        log ""
        log "=== $still_crashed pod(s) still not running — check logs ==="
        kubectl get pods -n azul --no-headers 2>/dev/null | grep -E "CrashLoopBackOff|Error" || true
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────
ACTION="${1:-fix}"

case "$ACTION" in
    --check|-c)
        cmd_check
        ;;
    fix|--fix)
        run_bootstrap
        init_security
        restart_metastore
        ;;
    --security-only|-s)
        init_security
        restart_metastore
        ;;
    -h|--help)
        echo "Usage: $0 [--check|--fix|--security-only]"
        echo ""
        echo "  (default)        Run full fix: bootstrap + security init + restart pods"
        echo "  --check          Just show current OpenSearch and metastore status"
        echo "  --security-only  Skip bootstrap, just reinit security + restart pods"
        echo "  --help           Show this help"
        exit 0
        ;;
    *)
        echo "Unknown option: $1 (try --help)"
        exit 1
        ;;
esac
