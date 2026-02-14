#!/usr/bin/env bash
# AZUL Teardown Script
# Completely removes all Azul resources from the Kubernetes cluster.
# Does NOT touch the external backup MinIO or backup data.
#
# Removes:
#   - Helm releases: azul, azul-infra
#   - PVCs in azul and azul-infra namespaces
#   - Namespaces: azul, azul-infra
#   - Helm releases: strimzi-kafka-operator, opensearch-operator
#   - CRDs: Strimzi (kafkas, kafkatopics, etc.) + OpenSearch (opensearchclusters, etc.)
#   - Operator namespaces: kafka, opensearch-operator
#   - CoreDNS azul hosts block
#
# Does NOT remove:
#   - External backup MinIO (docker-compose) or /data/backups/azul-minio/
#   - Talos PodSecurity exemptions (harmless to leave)
#   - cert-manager (shared with other services)
#   - Pi-hole DNS records
#   - /data/AZUL/ directory (charts, values, scripts)
#
# Usage:
#   ./azul-teardown.sh          # Interactive (asks for confirmation)
#   ./azul-teardown.sh --force  # Skip confirmation
#
# Compatible with: Ubuntu 22.04+, RHEL 9+
set -euo pipefail

export KUBECONFIG="/home/kp-admin/KUBS/kubeconfig"

DISCORD_WEBHOOK="https://discord.com/api/webhooks/1469836076154884215/SRt_iwtFSJVveLipv2DZ0i6h5tCLhejiD2mlmLUCllPtSgl0CfnRQGxRvy1Lk5lPJDLJ"

FORCE=false
[ "${1:-}" = "--force" ] && FORCE=true

# --- Helpers ---

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

send_discord() {
    local operation="$1" status="$2" details="${3:-}" color
    [ "$status" = "success" ] && color="65280" || color="16711680"
    curl -sf -H "Content-Type: application/json" -d "{
        \"embeds\": [{
            \"title\": \"Azul Teardown\",
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

# --- Pre-flight ---

log "=== AZUL COMPLETE TEARDOWN ==="
log ""
log "This will remove ALL Azul components from the cluster:"
log "  - Helm releases: azul, azul-infra, strimzi-kafka-operator, opensearch-operator"
log "  - Namespaces: azul, azul-infra, kafka, opensearch-operator"
log "  - All PVCs and data in those namespaces"
log "  - Strimzi and OpenSearch CRDs"
log "  - CoreDNS azul hosts block"
log ""
log "NOT removed: External backup MinIO, /data/AZUL/ files, Talos exemptions"
log ""

if [ "$FORCE" != "true" ]; then
    read -rp "Are you sure? Type 'yes' to proceed: " confirm
    if [ "$confirm" != "yes" ]; then
        log "Aborted."
        exit 0
    fi
fi

REMOVED=()
SKIPPED=()
ERRORS=()

# --- Step 1: Uninstall Azul app release ---

log ""
log "=== Step 1/7: Uninstall azul app release ==="
if helm status azul -n azul >/dev/null 2>&1; then
    if helm uninstall azul -n azul --timeout 5m; then
        log "Helm release 'azul' uninstalled"
        REMOVED+=("helm:azul")
    else
        log "WARNING: Failed to uninstall azul release"
        ERRORS+=("helm:azul")
    fi
else
    log "Helm release 'azul' not found, skipping"
    SKIPPED+=("helm:azul")
fi

# --- Step 2: Uninstall Azul infra release ---

log ""
log "=== Step 2/7: Uninstall azul-infra release ==="
if helm status azul-infra -n azul-infra >/dev/null 2>&1; then
    if helm uninstall azul-infra -n azul-infra --timeout 5m; then
        log "Helm release 'azul-infra' uninstalled"
        REMOVED+=("helm:azul-infra")
    else
        log "WARNING: Failed to uninstall azul-infra release"
        ERRORS+=("helm:azul-infra")
    fi
else
    log "Helm release 'azul-infra' not found, skipping"
    SKIPPED+=("helm:azul-infra")
fi

# --- Step 3: Delete PVCs ---

log ""
log "=== Step 3/7: Delete PVCs ==="
for ns in azul azul-infra; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        local_pvcs=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        if [ -n "$local_pvcs" ]; then
            for pvc in $local_pvcs; do
                log "Deleting PVC $pvc in $ns..."
                kubectl delete pvc "$pvc" -n "$ns" --timeout=60s 2>/dev/null || true
                REMOVED+=("pvc:$ns/$pvc")
            done
        else
            log "No PVCs in $ns"
        fi
    fi
done

# --- Step 4: Delete namespaces ---

log ""
log "=== Step 4/7: Delete azul namespaces ==="
for ns in azul azul-infra; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        log "Deleting namespace $ns..."
        if kubectl delete namespace "$ns" --timeout=120s 2>/dev/null; then
            log "Namespace $ns deleted"
            REMOVED+=("namespace:$ns")
        else
            log "WARNING: Namespace $ns deletion timed out, forcing..."
            # Attempt to remove finalizers on stuck resources
            kubectl get all -n "$ns" -o name 2>/dev/null | while read -r resource; do
                kubectl patch "$resource" -n "$ns" -p '{"metadata":{"finalizers":null}}' --type merge 2>/dev/null || true
            done
            kubectl delete namespace "$ns" --force --grace-period=0 2>/dev/null || true
            ERRORS+=("namespace:$ns (forced)")
        fi
    else
        log "Namespace $ns not found, skipping"
        SKIPPED+=("namespace:$ns")
    fi
done

# --- Step 5: Uninstall operators ---

log ""
log "=== Step 5/7: Uninstall operators ==="

# Strimzi
if helm status strimzi-kafka-operator -n kafka >/dev/null 2>&1; then
    if helm uninstall strimzi-kafka-operator -n kafka --timeout 3m; then
        log "Strimzi operator uninstalled"
        REMOVED+=("helm:strimzi-kafka-operator")
    else
        log "WARNING: Failed to uninstall Strimzi operator"
        ERRORS+=("helm:strimzi-kafka-operator")
    fi
else
    log "Strimzi operator not found, skipping"
    SKIPPED+=("helm:strimzi-kafka-operator")
fi

# OpenSearch operator
if helm status opensearch-operator -n opensearch-operator >/dev/null 2>&1; then
    if helm uninstall opensearch-operator -n opensearch-operator --timeout 3m; then
        log "OpenSearch operator uninstalled"
        REMOVED+=("helm:opensearch-operator")
    else
        log "WARNING: Failed to uninstall OpenSearch operator"
        ERRORS+=("helm:opensearch-operator")
    fi
else
    log "OpenSearch operator not found, skipping"
    SKIPPED+=("helm:opensearch-operator")
fi

# --- Step 6: Delete CRDs ---

log ""
log "=== Step 6/7: Delete CRDs ==="

# Strimzi CRDs
strimzi_crds=$(kubectl get crds -o name 2>/dev/null | grep "strimzi.io" || true)
if [ -n "$strimzi_crds" ]; then
    log "Deleting Strimzi CRDs..."
    echo "$strimzi_crds" | while read -r crd; do
        kubectl delete "$crd" --timeout=30s 2>/dev/null || true
        log "  Deleted $crd"
    done
    REMOVED+=("crds:strimzi")
else
    log "No Strimzi CRDs found"
    SKIPPED+=("crds:strimzi")
fi

# OpenSearch CRDs
os_crds=$(kubectl get crds -o name 2>/dev/null | grep "opensearch" || true)
if [ -n "$os_crds" ]; then
    log "Deleting OpenSearch CRDs..."
    echo "$os_crds" | while read -r crd; do
        kubectl delete "$crd" --timeout=30s 2>/dev/null || true
        log "  Deleted $crd"
    done
    REMOVED+=("crds:opensearch")
else
    log "No OpenSearch CRDs found"
    SKIPPED+=("crds:opensearch")
fi

# Delete operator namespaces
for ns in kafka opensearch-operator; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        log "Deleting namespace $ns..."
        kubectl delete namespace "$ns" --timeout=60s 2>/dev/null || true
        REMOVED+=("namespace:$ns")
    else
        SKIPPED+=("namespace:$ns")
    fi
done

# --- Step 7: Clean CoreDNS hosts block ---

log ""
log "=== Step 7/7: Clean CoreDNS hosts block ==="

# Get current Corefile
COREFILE=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null || true)

if echo "$COREFILE" | grep -q "keycloak-azul.kp.local"; then
    log "Removing azul hosts block from CoreDNS..."
    # Remove the hosts block containing azul entries
    NEW_COREFILE=$(echo "$COREFILE" | python3 -c "
import sys
content = sys.stdin.read()
lines = content.split('\n')
result = []
skip = False
for line in lines:
    if 'hosts {' in line or 'hosts{' in line:
        # Check if this hosts block contains azul entries
        # We'll collect the block first
        block_start = len(result)
        result.append(line)
        skip = True
        continue
    if skip:
        result.append(line)
        if line.strip() == '}':
            # Check if the block has azul entries
            block = '\n'.join(result[block_start:])
            if 'azul' in block:
                # Remove this entire block
                result = result[:block_start]
            skip = False
        continue
    result.append(line)
# Clean up extra blank lines
output = '\n'.join(result)
while '\n\n\n' in output:
    output = output.replace('\n\n\n', '\n\n')
print(output, end='')
")

    # Apply updated Corefile
    kubectl create configmap coredns -n kube-system \
        --from-literal=Corefile="$NEW_COREFILE" \
        --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

    kubectl rollout restart deployment coredns -n kube-system 2>/dev/null || true
    log "CoreDNS updated and restarted"
    REMOVED+=("coredns:azul-hosts")
else
    log "No azul hosts block found in CoreDNS"
    SKIPPED+=("coredns:azul-hosts")
fi

# --- Summary ---

log ""
log "============================================"
log "=== AZUL TEARDOWN COMPLETE ==="
log "============================================"
log ""
log "Removed (${#REMOVED[@]}):"
for item in "${REMOVED[@]}"; do
    log "  + $item"
done
if [ ${#SKIPPED[@]} -gt 0 ]; then
    log ""
    log "Skipped (${#SKIPPED[@]}) - already absent:"
    for item in "${SKIPPED[@]}"; do
        log "  - $item"
    done
fi
if [ ${#ERRORS[@]} -gt 0 ]; then
    log ""
    log "Errors (${#ERRORS[@]}):"
    for item in "${ERRORS[@]}"; do
        log "  ! $item"
    done
fi

log ""
log "Remaining namespaces:"
kubectl get namespaces --no-headers 2>/dev/null | while read -r line; do
    log "  $line"
done

# Verify clean
remaining=$(kubectl get namespaces --no-headers 2>/dev/null | grep -E "^(azul|azul-infra|kafka|opensearch-operator) " || true)
if [ -z "$remaining" ]; then
    log ""
    log "All Azul namespaces removed successfully."
    send_discord "Teardown" "success" "Removed: ${#REMOVED[@]} resources, Skipped: ${#SKIPPED[@]}, Errors: ${#ERRORS[@]}"
else
    log ""
    log "WARNING: Some namespaces still exist:"
    log "$remaining"
    send_discord "Teardown" "failed" "Some namespaces still exist after teardown"
fi
