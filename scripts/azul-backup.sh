#!/usr/bin/env bash
# AZUL Backup Script
# Starts the built-in Azul backup mechanism that continuously backs up
# Kafka events + binary streams to an external MinIO instance on the host.
#
# The backup pod runs as a continuous Deployment, subscribing to Kafka topics
# and replicating everything to the external S3 endpoint. OpenSearch indices
# are NOT backed up directly — they rebuild automatically during restore.
#
# Prerequisites:
#   - Docker or Podman installed (for external MinIO)
#   - kubectl and helm in PATH
#   - /data/AZUL/azul-values.yaml with recovery section configured
#   - /data/AZUL/docker-compose-backup.yaml present
#
# Usage:
#   ./azul-backup.sh [start|stop|status]
#     start  - Start external MinIO + deploy backup pod (default)
#     stop   - Stop backup mode (remove backup pod, keep MinIO running)
#     status - Show backup pod status and S3 bucket info
#
# Compatible with: Ubuntu 22.04+, RHEL 9+
set -euo pipefail

# Source central config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../azul.conf"

VALUES_FILE="${AZUL_DIR}/azul-values.yaml"
COMPOSE_FILE="${AZUL_DIR}/docker-compose-backup.yaml"
CHART_DIR="${AZUL_DIR}/azul-app/azul"
NAMESPACE="azul"
RELEASE="azul"

# External MinIO credentials (from azul.conf)
BACKUP_S3_ACCESS="${BACKUP_S3_USER}"
BACKUP_S3_SECRET="${BACKUP_S3_PASSWORD}"

# --- Helpers ---

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

send_discord() {
    local operation="$1" status="$2" details="${3:-}" color
    [ "$status" = "success" ] && color="65280" || color="16711680"
    curl -sf -H "Content-Type: application/json" -d "{
        \"embeds\": [{
            \"title\": \"Azul Backup\",
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

# Start external MinIO container
start_minio() {
    local compose_cmd
    compose_cmd=$(detect_compose)
    log "Using compose command: $compose_cmd"

    # Check if already running
    if $compose_cmd -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "running"; then
        log "External MinIO already running"
        return 0
    fi

    log "Starting external MinIO backup target..."
    $compose_cmd -f "$COMPOSE_FILE" up -d

    # Wait for healthy
    log "Waiting for MinIO to be healthy..."
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if $compose_cmd -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "healthy"; then
            log "External MinIO is healthy"
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done

    # Fallback: check if port is responding
    if curl -sf -o /dev/null "http://localhost:${BACKUP_MINIO_PORT}/minio/health/live" 2>/dev/null; then
        log "External MinIO is responding on port ${BACKUP_MINIO_PORT}"
        return 0
    fi

    log "ERROR: External MinIO failed to start within 60s"
    return 1
}

# Create s3-backup-keys secret in azul namespace
ensure_backup_secret() {
    if kubectl get secret s3-backup-keys -n "$NAMESPACE" >/dev/null 2>&1; then
        log "Secret s3-backup-keys already exists"
        return 0
    fi

    log "Creating s3-backup-keys secret..."
    kubectl create secret generic s3-backup-keys -n "$NAMESPACE" \
        --from-literal=access_key="$BACKUP_S3_ACCESS" \
        --from-literal=secret_key="$BACKUP_S3_SECRET"
    log "Secret s3-backup-keys created"
}

# Set recovery.mode in values file using sed
set_recovery_mode() {
    local mode="$1"
    sed -i "s/^  mode: .*/  mode: \"${mode}\"/" "$VALUES_FILE"
    log "Set recovery.mode to '$mode' in $VALUES_FILE"
}

# Get current recovery mode from values
get_recovery_mode() {
    sed -n 's/^  mode: "\(.*\)"/\1/p' "$VALUES_FILE" | head -1
}

# --- Commands ---

cmd_start() {
    log "=== Starting Azul Backup ==="

    # 1. Start external MinIO
    if ! start_minio; then
        send_discord "Backup Start" "failed" "External MinIO failed to start"
        exit 1
    fi

    # 2. Ensure backup secret exists
    ensure_backup_secret

    # 3. Set recovery mode to backup
    local current_mode
    current_mode=$(get_recovery_mode)
    if [ "$current_mode" = "backup" ]; then
        log "Recovery mode is already 'backup'"
    else
        set_recovery_mode "backup"
    fi

    # 4. Helm upgrade to deploy backup pod
    log "Running helm upgrade to deploy backup pod..."
    if ! helm upgrade "$RELEASE" "$CHART_DIR" -n "$NAMESPACE" -f "$VALUES_FILE" --timeout 5m; then
        log "ERROR: Helm upgrade failed"
        set_recovery_mode "off"
        send_discord "Backup Start" "failed" "Helm upgrade failed"
        exit 1
    fi
    # Test CA is baked into the chart's ca-certificates file — no re-apply needed.

    # 5. Wait for backup pod to be ready
    log "Waiting for backup pod to start..."
    sleep 10
    local backup_pod
    backup_pod=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=recovery-backup" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "$backup_pod" ]; then
        log "WARNING: No backup pod found yet. It may take a moment."
        sleep 15
        backup_pod=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=recovery-backup" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi

    if [ -n "$backup_pod" ]; then
        log "Backup pod: $backup_pod"
        kubectl wait --for=condition=ready "pod/$backup_pod" -n "$NAMESPACE" --timeout=120s 2>/dev/null || true

        log "Backup pod status:"
        kubectl get pod "$backup_pod" -n "$NAMESPACE" -o wide 2>/dev/null || true

        # Show recent logs
        log "Recent backup logs:"
        kubectl logs "$backup_pod" -n "$NAMESPACE" --tail=20 2>/dev/null || true
    fi

    local label
    label=$(python3 -c "
import re
with open('$VALUES_FILE') as f:
    for line in f:
        m = re.match(r'  label: \"(.*)\"', line)
        if m:
            print(m.group(1))
            break
" 2>/dev/null || echo "unknown")

    log ""
    log "=== Azul Backup STARTED ==="
    log "Mode: continuous (backup pod runs until stopped)"
    log "Label: $label"
    log "Target: External MinIO at ${FILESERVER_IP}:${BACKUP_MINIO_PORT}"
    log "Buckets: azul-backup-${label}-streams, azul-backup-${label}-events"
    log "Console: http://${FILESERVER_IP}:${BACKUP_MINIO_CONSOLE_PORT} (${BACKUP_S3_USER}/${BACKUP_S3_PASSWORD})"
    log ""
    log "To stop: $0 stop"
    log "To check: $0 status"

    send_discord "Backup Start" "success" "Backup pod running, label=$label, target=${FILESERVER_IP}:${BACKUP_MINIO_PORT}"
}

cmd_stop() {
    log "=== Stopping Azul Backup ==="

    local current_mode
    current_mode=$(get_recovery_mode)

    if [ "$current_mode" != "backup" ]; then
        log "Recovery mode is already '$current_mode' (not 'backup')"
        return 0
    fi

    # Set mode back to off
    set_recovery_mode "off"

    # Helm upgrade to remove backup pod
    log "Running helm upgrade to remove backup pod..."
    if ! helm upgrade "$RELEASE" "$CHART_DIR" -n "$NAMESPACE" -f "$VALUES_FILE" --timeout 5m; then
        log "ERROR: Helm upgrade failed"
        send_discord "Backup Stop" "failed" "Helm upgrade failed"
        exit 1
    fi

    # Wait for backup pod to terminate
    log "Waiting for backup pod to terminate..."
    sleep 5
    local attempts=0
    while [ $attempts -lt 24 ]; do
        if ! kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=recovery-backup" --no-headers 2>/dev/null | grep -q .; then
            log "Backup pod terminated"
            break
        fi
        sleep 5
        attempts=$((attempts + 1))
    done

    log "=== Azul Backup STOPPED ==="
    log "External MinIO is still running (data preserved at /data/backups/azul-minio/)"
    send_discord "Backup Stop" "success" "Backup pod removed, MinIO data preserved"
}

cmd_status() {
    log "=== Azul Backup Status ==="

    # Recovery mode
    local mode
    mode=$(get_recovery_mode)
    log "Recovery mode: $mode"

    # Backup pod
    log ""
    log "Backup pods:"
    kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=recovery-backup" -o wide 2>/dev/null || log "  (none)"

    # External MinIO
    log ""
    log "External MinIO:"
    if curl -sf -o /dev/null "http://localhost:${BACKUP_MINIO_PORT}/minio/health/live" 2>/dev/null; then
        log "  Status: HEALTHY (port ${BACKUP_MINIO_PORT})"
        log "  Console: http://${FILESERVER_IP}:${BACKUP_MINIO_CONSOLE_PORT}"
        log "  Data dir: ${BACKUP_DIR}/"

        # List buckets if mc is available (optional)
        if command -v mc >/dev/null 2>&1; then
            mc alias set azul-bk http://localhost:${BACKUP_MINIO_PORT} "$BACKUP_S3_ACCESS" "$BACKUP_S3_SECRET" >/dev/null 2>&1 || true
            log "  Buckets:"
            mc ls azul-bk/ 2>/dev/null | while read -r line; do log "    $line"; done
        else
            log "  (Install 'mc' CLI to list buckets, or use web console)"
        fi

        # Show data directory size
        if [ -d /data/backups/azul-minio ]; then
            local size
            size=$(du -sh /data/backups/azul-minio 2>/dev/null | cut -f1)
            log "  Backup data size: $size"
        fi
    else
        log "  Status: NOT RUNNING"
    fi

    # Backup secret
    log ""
    if kubectl get secret s3-backup-keys -n "$NAMESPACE" >/dev/null 2>&1; then
        log "Secret s3-backup-keys: EXISTS"
    else
        log "Secret s3-backup-keys: MISSING (will be created on backup start)"
    fi
}

# --- Main ---

ACTION="${1:-start}"

case "$ACTION" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    *)
        echo "Usage: $0 [start|stop|status]"
        echo "  start  - Start external MinIO + deploy backup pod (default)"
        echo "  stop   - Stop backup mode (remove backup pod)"
        echo "  status - Show backup pod and MinIO status"
        exit 1
        ;;
esac
