#!/usr/bin/env bash
# AZUL Restore Script
# Restores Azul data from an external MinIO backup.
#
# The restore runs as a one-shot Kubernetes Job that replays all backed-up
# Kafka events and binary streams back into the system. OpenSearch indices
# are rebuilt automatically during the replay — they are NOT restored directly.
#
# Prerequisites:
#   - External MinIO running with backup data (docker-compose-backup.yaml)
#   - Azul Stages 1+2 deployed (infra + core app running)
#   - s3-backup-keys secret in azul namespace
#
# Usage:
#   ./azul-restore.sh              # Restore from latest backup label
#   ./azul-restore.sh --label 02   # Restore from specific label
#   ./azul-restore.sh --check      # Check backup status without restoring
#
# Compatible with: Ubuntu 22.04+, RHEL 9+
set -euo pipefail

export KUBECONFIG="/home/kp-admin/KUBS/kubeconfig"

AZUL_DIR="/data/AZUL"
VALUES_FILE="${AZUL_DIR}/azul-values.yaml"
COMPOSE_FILE="${AZUL_DIR}/docker-compose-backup.yaml"
CHART_DIR="${AZUL_DIR}/azul-app/azul"
NAMESPACE="azul"
RELEASE="azul"

DISCORD_WEBHOOK="https://discord.com/api/webhooks/1469836076154884215/SRt_iwtFSJVveLipv2DZ0i6h5tCLhejiD2mlmLUCllPtSgl0CfnRQGxRvy1Lk5lPJDLJ"

BACKUP_S3_ACCESS="azul-backup"
BACKUP_S3_SECRET="azul-backup-secret"
OPENSEARCH_CA="${AZUL_DIR}/opensearch-ca.crt"

# --- Helpers ---

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

die() { log "FATAL: $*"; send_discord "Restore" "failed" "$*"; exit 1; }

send_discord() {
    local operation="$1" status="$2" details="${3:-}" color
    [ "$status" = "success" ] && color="65280" || color="16711680"
    curl -sf -H "Content-Type: application/json" -d "{
        \"embeds\": [{
            \"title\": \"Azul Restore\",
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

detect_compose() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v podman-compose >/dev/null 2>&1; then
        echo "podman-compose"
    elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
        echo "podman compose"
    else
        log "ERROR: Neither docker compose nor podman-compose found"
        exit 1
    fi
}

get_label() {
    python3 -c "
import re
with open('$VALUES_FILE') as f:
    for line in f:
        m = re.match(r'  label: \"(.*)\"', line)
        if m:
            print(m.group(1))
            break
" 2>/dev/null || echo "01"
}

set_recovery_mode() {
    local mode="$1"
    sed -i "s/^  mode: .*/  mode: \"${mode}\"/" "$VALUES_FILE"
    log "Set recovery.mode to '$mode' in $VALUES_FILE"
}

reapply_test_ca() {
    # helm upgrade resets the opensearch certs configmap, stripping the appended Test CA.
    # Without it, OpenSearch can't validate Keycloak TLS → OIDC auth fails → API 500.
    if [ ! -f "$OPENSEARCH_CA" ]; then
        log "WARNING: $OPENSEARCH_CA not found, skipping Test CA re-application"
        return
    fi
    local ca_bundle
    ca_bundle=$(kubectl get configmap azul-opensearch-certs -n azul-infra \
        -o jsonpath='{.data.ca-certificates}' 2>/dev/null)
    if echo "$ca_bundle" | grep -q "Test CA"; then
        return  # Already present
    fi
    log "Re-applying Test CA to opensearch certs configmap..."
    local tmpfile="/tmp/os-ca-bundle-$$.pem"
    echo "$ca_bundle" > "$tmpfile"
    echo "" >> "$tmpfile"
    echo "# Test CA for Keycloak (self-signed)" >> "$tmpfile"
    cat "$OPENSEARCH_CA" >> "$tmpfile"
    kubectl create configmap azul-opensearch-certs -n azul-infra \
        --from-file=ca-certificates="$tmpfile" \
        --dry-run=client -o yaml | \
        kubectl apply --server-side --field-manager=helm --force-conflicts -f - >/dev/null 2>&1
    rm -f "$tmpfile"
    log "Test CA re-applied to opensearch certs configmap"
}

# --- Commands ---

cmd_check() {
    local label
    label=$(get_label)

    log "=== Checking Backup Status ==="
    log "Label: $label"
    log "Expected buckets: azul-backup-${label}-streams, azul-backup-${label}-events"

    # Check external MinIO
    if ! curl -sf -o /dev/null "http://localhost:9100/minio/health/live" 2>/dev/null; then
        log "External MinIO is NOT running"
        log "Start it with: docker compose -f $COMPOSE_FILE up -d"
        return 1
    fi
    log "External MinIO: HEALTHY"

    # Check backup data directory
    if [ -d /data/backups/azul-minio ]; then
        local size
        size=$(du -sh /data/backups/azul-minio 2>/dev/null | cut -f1)
        log "Backup data directory: /data/backups/azul-minio ($size)"

        # List bucket directories
        if [ -d "/data/backups/azul-minio/azul-backup-${label}-streams" ]; then
            local streams_size
            streams_size=$(du -sh "/data/backups/azul-minio/azul-backup-${label}-streams" 2>/dev/null | cut -f1)
            log "  Streams bucket: azul-backup-${label}-streams ($streams_size)"
        else
            log "  Streams bucket: NOT FOUND"
        fi

        if [ -d "/data/backups/azul-minio/azul-backup-${label}-events" ]; then
            local events_size
            events_size=$(du -sh "/data/backups/azul-minio/azul-backup-${label}-events" 2>/dev/null | cut -f1)
            log "  Events bucket: azul-backup-${label}-events ($events_size)"
        else
            log "  Events bucket: NOT FOUND"
        fi
    else
        log "Backup data directory: NOT FOUND"
    fi

    # Check azul namespace
    if kubectl get namespace azul >/dev/null 2>&1; then
        local pod_count
        pod_count=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        log "Azul namespace: EXISTS ($pod_count running pods)"
    else
        log "Azul namespace: NOT FOUND (need to deploy Stages 1+2 before restore)"
    fi

    # Check backup secret
    if kubectl get secret s3-backup-keys -n azul >/dev/null 2>&1; then
        log "Secret s3-backup-keys: EXISTS"
    else
        log "Secret s3-backup-keys: MISSING"
    fi
}

cmd_restore() {
    local label
    label=$(get_label)

    log "=== Starting Azul Restore ==="
    log "Label: $label"
    log "Source: External MinIO at 192.168.66.41:9100"
    log "Buckets: azul-backup-${label}-streams, azul-backup-${label}-events"

    # --- Pre-flight checks ---

    # 1. External MinIO must be running
    if ! curl -sf -o /dev/null "http://localhost:9100/minio/health/live" 2>/dev/null; then
        log "External MinIO not running, starting it..."
        local compose_cmd
        compose_cmd=$(detect_compose)
        $compose_cmd -f "$COMPOSE_FILE" up -d
        sleep 10
        if ! curl -sf -o /dev/null "http://localhost:9100/minio/health/live" 2>/dev/null; then
            die "External MinIO failed to start"
        fi
    fi
    log "External MinIO: HEALTHY"

    # 2. Check backup data exists
    if [ ! -d "/data/backups/azul-minio/azul-backup-${label}-streams" ] && \
       [ ! -d "/data/backups/azul-minio/azul-backup-${label}-events" ]; then
        die "No backup data found for label '$label'. Check /data/backups/azul-minio/"
    fi
    log "Backup data found for label '$label'"

    # 3. Azul core must be running (at least Stages 1+2)
    if ! kubectl get namespace azul >/dev/null 2>&1; then
        die "Azul namespace not found. Deploy Stages 1+2 first."
    fi

    if ! helm status azul -n azul >/dev/null 2>&1; then
        die "Azul Helm release not found. Deploy Stage 2 first."
    fi

    # 4. Ensure backup secret
    if ! kubectl get secret s3-backup-keys -n "$NAMESPACE" >/dev/null 2>&1; then
        log "Creating s3-backup-keys secret..."
        kubectl create secret generic s3-backup-keys -n "$NAMESPACE" \
            --from-literal=access_key="$BACKUP_S3_ACCESS" \
            --from-literal=secret_key="$BACKUP_S3_SECRET"
    fi

    # --- Run restore ---

    # Set mode to restore
    set_recovery_mode "restore"

    # Helm upgrade to create restore Job
    log "Running helm upgrade to create restore Job..."
    if ! helm upgrade "$RELEASE" "$CHART_DIR" -n "$NAMESPACE" -f "$VALUES_FILE" --timeout 5m; then
        log "ERROR: Helm upgrade failed"
        set_recovery_mode "off"
        die "Helm upgrade failed during restore"
    fi
    reapply_test_ca

    # Wait for restore Job to appear
    log "Waiting for restore Job to start..."
    sleep 15

    local restore_job
    restore_job=$(kubectl get jobs -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
        | grep "recovery-restore" | head -1 || true)

    if [ -z "$restore_job" ]; then
        log "WARNING: No restore job found. Checking pods..."
        kubectl get pods -n "$NAMESPACE" --no-headers | grep -i "restore" || true
        sleep 15
        restore_job=$(kubectl get jobs -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
            | grep "recovery-restore" | head -1 || true)
    fi

    if [ -n "$restore_job" ]; then
        log "Restore Job: $restore_job"

        # Monitor the job
        log "Monitoring restore job (this may take a while)..."
        local attempts=0
        local max_attempts=360  # 30 minutes max
        while [ $attempts -lt $max_attempts ]; do
            local status
            status=$(kubectl get job "$restore_job" -n "$NAMESPACE" \
                -o jsonpath='{range .status.conditions[*]}{.type}{"\n"}{end}' 2>/dev/null || echo "")

            if echo "$status" | grep -q "Complete"; then
                log "Restore Job completed successfully!"
                break
            elif echo "$status" | grep -q "Failed"; then
                log "ERROR: Restore Job failed"
                kubectl logs "job/$restore_job" -n "$NAMESPACE" --tail=50 2>/dev/null || true
                set_recovery_mode "off"
                helm upgrade "$RELEASE" "$CHART_DIR" -n "$NAMESPACE" -f "$VALUES_FILE" --timeout 5m 2>/dev/null || true
                send_discord "Restore" "failed" "Restore job failed for label=$label"
                exit 1
            fi

            # Show progress every 30 seconds
            if [ $((attempts % 6)) -eq 0 ]; then
                local pod_name
                pod_name=$(kubectl get pods -n "$NAMESPACE" -l "job-name=$restore_job" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
                if [ -n "$pod_name" ]; then
                    local last_log
                    last_log=$(kubectl logs "$pod_name" -n "$NAMESPACE" --tail=1 2>/dev/null || echo "waiting...")
                    log "  Progress: $last_log"
                fi
            fi

            sleep 5
            attempts=$((attempts + 1))
        done

        if [ $attempts -ge $max_attempts ]; then
            log "WARNING: Restore job still running after 30 minutes"
        fi
    else
        log "WARNING: Could not find restore job"
    fi

    # Set mode back to off (or backup if you want continuous backup after restore)
    log "Setting recovery mode back to 'off'..."
    set_recovery_mode "off"
    helm upgrade "$RELEASE" "$CHART_DIR" -n "$NAMESPACE" -f "$VALUES_FILE" --timeout 5m 2>/dev/null || true
    reapply_test_ca

    log ""
    log "=== RESTORE COMPLETE ==="
    log "Label: $label"
    log "OpenSearch indices will rebuild as events are replayed."
    log "Check: kubectl get pods -n azul"
    send_discord "Restore" "success" "Restore complete for label=$label"
}

# --- Main ---

LABEL_OVERRIDE=""
ACTION="restore"

while [ $# -gt 0 ]; do
    case "$1" in
        --check)
            ACTION="check"
            shift
            ;;
        --label)
            LABEL_OVERRIDE="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--check] [--label LABEL]"
            echo "  (default)    - Run restore from backup"
            echo "  --check      - Check backup status only"
            echo "  --label ID   - Use specific backup label (default: from values file)"
            exit 1
            ;;
    esac
done

# Apply label override if provided
if [ -n "$LABEL_OVERRIDE" ]; then
    log "Overriding backup label to: $LABEL_OVERRIDE"
    sed -i "s/^  label: .*/  label: \"${LABEL_OVERRIDE}\"/" "$VALUES_FILE"
fi

case "$ACTION" in
    check)   cmd_check ;;
    restore) cmd_restore ;;
esac
