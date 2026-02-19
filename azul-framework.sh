#!/usr/bin/env bash
# =================================================================
# AZUL Deployment Framework
# =================================================================
# Single entry point for AZUL deployment lifecycle:
#   - File server sync (from internal nginx)
#   - Container registry validation and push
#   - Install/uninstall for each of the 3 stages
#
# Usage:
#   azul-framework.sh sync <service-ip> [port]   Sync files from file server
#   azul-framework.sh validate [section]          Check registry for required images
#   azul-framework.sh push     [section]          Pull upstream images -> push to registry
#   azul-framework.sh install  [section]          Full install with pre-checks
#   azul-framework.sh uninstall [section]         Clean uninstall
#   azul-framework.sh status   [section]          Show current state
#
# Sections: infra | app | plugins | all
#
# Bootstrap:
#   curl -o azul-framework.sh http://<ip>:8888/AZUL/azul-framework.sh
#   chmod +x azul-framework.sh
#   ./azul-framework.sh sync <service-ip>
#
# Compatible with: Ubuntu 22.04+, RHEL 9+
# =================================================================
set -euo pipefail

# --- AZUL_DIR = directory where this script lives ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AZUL_DIR="$SCRIPT_DIR"

# Source config if available (not present during first sync)
if [ -f "${AZUL_DIR}/azul.conf" ]; then
    source "${AZUL_DIR}/azul.conf"
fi

# Derived values (computed from static config, never stored in azul.conf)
FILESERVER="${SERVICE_IP:-}:${FILESERVER_PORT:-8888}"
REGISTRY="${SERVICE_IP:-}:${REGISTRY_PORT:-5000}"

LOG_FILE="${AZUL_DIR}/framework.log"
INFRA_IMAGES="${AZUL_DIR}/images-infra.txt"
APP_IMAGES="${AZUL_DIR}/images-app.txt"
PLUGINS_IMAGES="${AZUL_DIR}/images-plugins.txt"
DEPLOY_SCRIPT="${AZUL_DIR}/scripts/azul-deploy.sh"
TEARDOWN_SCRIPT="${AZUL_DIR}/scripts/azul-teardown.sh"

FORCE=false

# Detect container runtime (docker or podman)
if command -v docker >/dev/null 2>&1; then
    CONTAINER_RT="docker"
elif command -v podman >/dev/null 2>&1; then
    CONTAINER_RT="podman"
else
    CONTAINER_RT=""
fi

# =================================================================
# LOGGING
# =================================================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    [ -n "${LOG_FILE:-}" ] && echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_err() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"
    echo "$msg" >&2
    [ -n "${LOG_FILE:-}" ] && echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
    log_err "$*"
    exit 1
}

header() {
    log ""
    log "============================================"
    log "  $*"
    log "============================================"
}

print_access_info() {
    local creds_file="${AZUL_DIR}/.azul-credentials"
    log ""
    log "============================================"
    log "  AZUL ACCESS INFORMATION"
    log "============================================"
    log ""
    log "  URLs:"
    log "    Web UI:      https://${AZUL_HOST}"
    log "    Keycloak:    https://${KEYCLOAK_HOST}"
    log "    OpenSearch:  https://${OPENSEARCH_HOST}"
    log "    MinIO:       https://${MINIO_HOST}"
    log ""
    log "  Accounts:"
    log "    Test user:   ${TEST_USER} / ${TEST_PASSWORD}"
    log "    Admin user:  ${ADMIN_USER} / ${ADMIN_PASSWORD}"
    log ""
    log "  Keycloak Admin:"
    log "    Username:    admin"
    local kc_pass=""
    if [ -f "$creds_file" ]; then
        kc_pass=$(grep '^KC_ADMIN_PASSWORD=' "$creds_file" 2>/dev/null | cut -d= -f2) || true
    fi
    if [ -n "$kc_pass" ]; then
        log "    Password:    $kc_pass"
    else
        log "    Password:    (see .azul-credentials)"
    fi
    log ""
    log "============================================"
}

# =================================================================
# TWO-COLUMN IMAGE MANIFEST HELPERS
# =================================================================

# Read manifest, returning pipe-delimited lines: upstream|registry_path
read_manifest() {
    local file="$1"
    [ -f "$file" ] || die "Manifest not found: $file"
    grep -v '^#' "$file" | grep -v '^$' | sed 's/[[:space:]]*|[[:space:]]*/|/'
}

# Parse a manifest line into UPSTREAM_IMAGE and REGISTRY_PATH
parse_manifest_line() {
    local line="$1"
    UPSTREAM_IMAGE="${line%%|*}"
    UPSTREAM_IMAGE="${UPSTREAM_IMAGE%% }"
    UPSTREAM_IMAGE="${UPSTREAM_IMAGE% }"
    REGISTRY_PATH="${line##*|}"
    REGISTRY_PATH="${REGISTRY_PATH## }"
    REGISTRY_PATH="${REGISTRY_PATH# }"
}

# Get manifest file for a section
manifest_for() {
    case "$1" in
        infra)   echo "$INFRA_IMAGES" ;;
        app)     echo "$APP_IMAGES" ;;
        plugins) echo "$PLUGINS_IMAGES" ;;
        *) die "Unknown section: $1" ;;
    esac
}

# =================================================================
# REGISTRY FUNCTIONS
# =================================================================

# Check if image exists in private registry using REGISTRY_PATH
# Input: registry_path (e.g., "asdazul/dispatcher:9.0.0")
check_image_in_registry() {
    local registry_path="$1"
    local repo="${registry_path%%:*}"
    local tag="${registry_path##*:}"

    local url="http://${REGISTRY}/v2/${repo}/tags/list"
    local response
    response=$(curl -sf "$url" 2>/dev/null) || return 1

    echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tags = data.get('tags', []) or []
sys.exit(0 if '${tag}' in tags else 1)
" 2>/dev/null
}

# Validate all images for a section
validate_section() {
    local section="$1"
    local manifest
    manifest=$(manifest_for "$section")

    log "Validating $section images against registry ${REGISTRY}..."

    local found=0 missing=0 total=0
    local missing_list=""

    while IFS= read -r line; do
        parse_manifest_line "$line"
        total=$((total + 1))
        if check_image_in_registry "$REGISTRY_PATH"; then
            found=$((found + 1))
        else
            missing=$((missing + 1))
            missing_list="${missing_list}  - ${UPSTREAM_IMAGE} -> ${REGISTRY_PATH}\n"
        fi
    done < <(read_manifest "$manifest")

    log "  Section: $section"
    log "  Total: $total | Found: $found | Missing: $missing"

    if [ "$missing" -gt 0 ]; then
        log ""
        log "  Missing images:"
        echo -e "$missing_list" | while IFS= read -r l; do
            [ -n "$l" ] && log "$l"
        done
        return 1
    fi

    log "  All $section images present in registry."
    return 0
}

# Push a single image: pull upstream, tag for registry, push
push_single_image() {
    local upstream="$1" registry_path="$2"
    local local_tag="${REGISTRY}/${registry_path}"

    log "  Pulling: $upstream"
    if ! $CONTAINER_RT pull "$upstream" 2>>"$LOG_FILE"; then
        log_err "  Failed to pull: $upstream"
        return 1
    fi

    log "  Tagging: $local_tag"
    $CONTAINER_RT tag "$upstream" "$local_tag" 2>>"$LOG_FILE"

    log "  Pushing: $local_tag"
    if ! $CONTAINER_RT push "$local_tag" 2>>"$LOG_FILE"; then
        log_err "  Failed to push: $local_tag"
        return 1
    fi

    if check_image_in_registry "$registry_path"; then
        log "  OK: $registry_path"
    else
        log_err "  Push verification failed: $registry_path"
        return 1
    fi
}

# Push all missing images for a section
push_section() {
    local section="$1"
    local manifest
    manifest=$(manifest_for "$section")

    log "Checking $section images for push to ${REGISTRY}..."

    local to_push_upstream=() to_push_registry=()
    while IFS= read -r line; do
        parse_manifest_line "$line"
        if ! check_image_in_registry "$REGISTRY_PATH"; then
            to_push_upstream+=("$UPSTREAM_IMAGE")
            to_push_registry+=("$REGISTRY_PATH")
        fi
    done < <(read_manifest "$manifest")

    if [ ${#to_push_upstream[@]} -eq 0 ]; then
        log "All $section images already in registry. Nothing to push."
        return 0
    fi

    log "${#to_push_upstream[@]} images need to be pushed for $section:"
    for rp in "${to_push_registry[@]}"; do
        log "  - $rp"
    done

    if [ "$FORCE" != "true" ]; then
        echo ""
        read -rp "Download and push ${#to_push_upstream[@]} images to registry? (y/n): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            log "Push cancelled by user."
            return 1
        fi
    fi

    log ""
    local pushed=0 failed=0
    for i in "${!to_push_upstream[@]}"; do
        if push_single_image "${to_push_upstream[$i]}" "${to_push_registry[$i]}"; then
            pushed=$((pushed + 1))
        else
            failed=$((failed + 1))
        fi
    done

    log ""
    log "Push complete: $pushed succeeded, $failed failed (of ${#to_push_upstream[@]} total)"
    [ "$failed" -eq 0 ] && return 0 || return 1
}

# =================================================================
# REGISTRY OVERRIDE GENERATION
# =================================================================

# Generate --set-string flags for Helm to use private registry images.
# Reads image manifests and maps known upstream patterns to Helm value paths.
generate_registry_overrides() {
    local section="$1"
    local overrides=""

    case "$section" in
        app|plugins)
            # All asdazul/* images handled by customRegistry
            overrides="--set-string images.customRegistry=${REGISTRY}/asdazul/"

            # External images need individual overrides
            local manifest
            manifest=$(manifest_for "$section")
            while IFS= read -r line; do
                parse_manifest_line "$line"
                local helm_key=""
                case "$UPSTREAM_IMAGE" in
                    *redis:*)     helm_key="images.external.redis" ;;
                    *alloy:*)     helm_key="images.external.alloy" ;;
                    *burrow:*)    helm_key="images.external.burrow" ;;
                    *tika:*)      helm_key="images.external.tika_external" ;;
                    *git-sync:*)  helm_key="images.external.git-sync" ;;
                esac
                if [ -n "$helm_key" ]; then
                    overrides+=" --set-string ${helm_key}=${REGISTRY}/${REGISTRY_PATH}"
                fi
            done < <(read_manifest "$manifest")
            ;;
        infra)
            local manifest
            manifest=$(manifest_for infra)
            while IFS= read -r line; do
                parse_manifest_line "$line"
                local helm_key=""
                case "$UPSTREAM_IMAGE" in
                    *minio/minio:*)
                        overrides+=" --set-string minio.main.image=${REGISTRY}/${REGISTRY_PATH}"
                        overrides+=" --set-string minio.backup.image=${REGISTRY}/${REGISTRY_PATH}"
                        continue
                        ;;
                    *keycloak:*)  helm_key="keycloak.image" ;;
                    *kafkactl:*)  helm_key="kafka.kafkactl.image" ;;
                    *postgres:*)  helm_key="keycloak.postgres.image" ;;
                esac
                if [ -n "$helm_key" ]; then
                    overrides+=" --set-string ${helm_key}=${REGISTRY}/${REGISTRY_PATH}"
                fi
            done < <(read_manifest "$manifest")
            ;;
    esac

    echo "$overrides"
}

# =================================================================
# FILE SERVER SYNC
# =================================================================

# Recursive directory download using curl (fallback when wget unavailable)
sync_with_curl() {
    local dest="$1" url="$2" prefix="$3"
    mkdir -p "${dest}/${prefix}"

    local listing
    listing=$(curl -sf "$url" 2>/dev/null) || return 1

    local links
    links=$(echo "$listing" | grep -oP 'href="\K[^"]+' | grep -v '^\.\.' | grep -v '^/$')

    for link in $links; do
        if [[ "$link" == */ ]]; then
            sync_with_curl "$dest" "${url}${link}" "${prefix}/${link%/}"
        else
            curl -sf -o "${dest}/${prefix}/${link}" "${url}${link}" 2>>"${LOG_FILE:-/dev/null}" || \
                log_err "Failed to download: ${url}${link}"
        fi
    done
}

cmd_sync() {
    header "FILE SERVER SYNC"

    # Server IP from argument, or from azul.conf if loaded
    local server_ip="${SYNC_SERVER_IP:-${SERVICE_IP:-}}"
    local server_port="${SYNC_SERVER_PORT:-${FILESERVER_PORT:-8888}}"

    if [ -z "$server_ip" ]; then
        die "No file server IP. Usage: $0 sync <service-ip> [port]"
    fi

    local fileserver_url="http://${server_ip}:${server_port}/AZUL/"

    # 1. Health check
    log "Checking file server at ${fileserver_url}..."
    if ! curl -sf --connect-timeout 5 "${fileserver_url}" >/dev/null 2>&1; then
        die "File server unreachable at ${fileserver_url}"
    fi
    log "File server is reachable."

    # 2. Download to staging
    log "Syncing files from file server..."
    local staging_dir
    staging_dir=$(mktemp -d /tmp/azul-sync.XXXXXX)
    trap "rm -rf '$staging_dir'" EXIT

    if command -v wget >/dev/null 2>&1; then
        wget -q --mirror --no-parent --no-host-directories \
            --reject "index.html*" \
            --cut-dirs=0 \
            -P "$staging_dir" \
            "${fileserver_url}" 2>>"${LOG_FILE:-/dev/null}" || die "wget sync failed"
    elif command -v curl >/dev/null 2>&1; then
        log "wget not found, using curl fallback (install wget for better sync: dnf install wget)"
        sync_with_curl "$staging_dir" "${fileserver_url}" "AZUL"
    else
        die "Neither wget nor curl found."
    fi

    # 3. Validate structure
    log "Validating downloaded structure..."
    local required_dirs=("AZUL/azul-app" "AZUL/scripts")
    local required_files=("AZUL/azul.conf" "AZUL/azul-infra-values.yaml" "AZUL/azul-values.yaml" "AZUL/images-infra.txt")
    local valid=true

    for dir in "${required_dirs[@]}"; do
        if [ ! -d "${staging_dir}/${dir}" ]; then
            log_err "Missing required directory: $dir"
            valid=false
        fi
    done
    for file in "${required_files[@]}"; do
        if [ ! -f "${staging_dir}/${file}" ]; then
            log_err "Missing required file: $file"
            valid=false
        fi
    done

    if [ "$valid" != "true" ]; then
        die "File server structure validation failed. Aborting sync."
    fi
    log "Structure validated."

    # 4. Copy to AZUL_DIR, protecting sensitive files
    log "Copying synced files to ${AZUL_DIR}..."
    local protected_files=(".azul-credentials" "framework.log" "opensearch-ca.crt")

    if command -v rsync >/dev/null 2>&1; then
        local rsync_excludes=()
        for pf in "${protected_files[@]}"; do
            rsync_excludes+=(--exclude "$pf")
        done
        rsync -a "${rsync_excludes[@]}" "${staging_dir}/AZUL/" "${AZUL_DIR}/" 2>>"${LOG_FILE:-/dev/null}"
    else
        for pf in "${protected_files[@]}"; do
            [ -f "${AZUL_DIR}/${pf}" ] && cp "${AZUL_DIR}/${pf}" "/tmp/azul-protect-${pf}" 2>/dev/null || true
        done
        cp -r "${staging_dir}/AZUL/"* "${AZUL_DIR}/" 2>>"${LOG_FILE:-/dev/null}" || true
        for pf in "${protected_files[@]}"; do
            [ -f "/tmp/azul-protect-${pf}" ] && mv "/tmp/azul-protect-${pf}" "${AZUL_DIR}/${pf}" 2>/dev/null || true
        done
    fi

    # 5. Make scripts executable
    chmod +x "${AZUL_DIR}/scripts/"*.sh 2>/dev/null || true
    chmod +x "${AZUL_DIR}/azul-framework.sh" 2>/dev/null || true

    # 6. Post-sync patches (upstream chart fixes)
    patch_templates

    # 7. Re-source config (may have been updated by sync)
    if [ -f "${AZUL_DIR}/azul.conf" ]; then
        source "${AZUL_DIR}/azul.conf"
        FILESERVER="${SERVICE_IP}:${FILESERVER_PORT}"
        REGISTRY="${SERVICE_IP}:${REGISTRY_PORT}"
    fi

    log "Sync complete."
    log ""
    log "Protected (NOT overwritten): ${protected_files[*]}"
    log ""
    log "Next steps:"
    log "  1. Review azul.conf (edit on file server and re-sync if needed)"
    log "  2. $0 validate all"
    log "  3. $0 push all"
    log "  4. $0 install infra"

    trap - EXIT
    rm -rf "$staging_dir"
}

# Post-sync template patches for upstream chart issues
patch_templates() {
    # Patch postgres.yaml: hardcoded image -> templatable value
    local pg_template="${AZUL_DIR}/azul-app/infra/templates/keycloak/postgres.yaml"
    if [ -f "$pg_template" ] && grep -q 'image: postgres:' "$pg_template"; then
        sed -i 's|image: postgres:[0-9.]*|image: {{ .Values.keycloak.postgres.image \| default "postgres:17.4" }}|' "$pg_template"
        log "Patched postgres.yaml for registry override support"
    fi
}

# =================================================================
# VALIDATE COMMAND
# =================================================================

cmd_validate() {
    local section="${1:-all}"
    header "REGISTRY VALIDATION: $section"

    if ! curl -sf --connect-timeout 5 "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
        die "Registry unreachable at http://${REGISTRY}"
    fi
    log "Registry at ${REGISTRY} is reachable."
    log ""

    local sections=()
    case "$section" in
        all) sections=(infra app plugins) ;;
        *)   sections=("$section") ;;
    esac

    local all_ok=true
    for s in "${sections[@]}"; do
        if ! validate_section "$s"; then
            all_ok=false
        fi
        log ""
    done

    if [ "$all_ok" = "true" ]; then
        log "All images validated successfully."
        return 0
    else
        log_err "Some images are missing from the registry."
        log "Run: $0 push $section"
        return 1
    fi
}

# =================================================================
# PUSH COMMAND
# =================================================================

cmd_push() {
    local section="${1:-all}"
    header "REGISTRY PUSH: $section"

    if ! curl -sf --connect-timeout 5 "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
        die "Registry unreachable at http://${REGISTRY}"
    fi

    if [ -z "$CONTAINER_RT" ]; then
        die "Neither docker nor podman found. Install one to push images."
    fi
    log "Using container runtime: $CONTAINER_RT"

    local sections=()
    case "$section" in
        all) sections=(infra app plugins) ;;
        *)   sections=("$section") ;;
    esac

    local all_ok=true
    for s in "${sections[@]}"; do
        if ! push_section "$s"; then
            all_ok=false
        fi
        log ""
    done

    if [ "$all_ok" = "true" ]; then
        log "All images pushed successfully."
    else
        log_err "Some images failed to push. Check $LOG_FILE for details."
        return 1
    fi
}

# =================================================================
# INSTALL COMMAND
# =================================================================

cmd_install() {
    local section="${1:-all}"
    header "INSTALL: $section"

    local sections=()
    case "$section" in
        all) sections=(infra app plugins) ;;
        *)   sections=("$section") ;;
    esac

    for s in "${sections[@]}"; do
        install_section "$s"
    done

    print_access_info
}

install_section() {
    local section="$1"
    log ""
    log "--- Installing section: $section ---"

    # Phase 1: Verify files exist
    log "Phase 1: Checking required files..."
    if ! preflight_files "$section"; then
        die "File pre-flight check failed for $section. Run: $0 sync <service-ip>"
    fi
    log "  Files: OK"

    # Phase 2: Validate registry images
    log "Phase 2: Validating registry images..."
    if ! validate_section "$section"; then
        log_err "Registry images missing for $section."
        if [ "$FORCE" != "true" ]; then
            echo ""
            read -rp "Push missing images to registry now? (y/n): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                push_section "$section" || die "Image push failed for $section."
            else
                die "Cannot install $section without required images. Run: $0 push $section"
            fi
        else
            push_section "$section" || die "Image push failed for $section."
        fi
    fi
    log "  Registry: OK"

    # Phase 3: Deploy
    log "Phase 3: Deploying $section..."
    if [ ! -x "$DEPLOY_SCRIPT" ]; then
        die "Deploy script not found or not executable: $DEPLOY_SCRIPT"
    fi
    bash "$DEPLOY_SCRIPT" "$section"
    log "  Deploy: OK"

    # Phase 4: Post-install verification
    log "Phase 4: Post-install verification..."
    verify_section "$section"

    log ""
    log "=== Section $section installed successfully ==="
}

preflight_files() {
    local section="$1"
    local ok=true

    [ -f "${AZUL_DIR}/.azul-credentials" ] || { log_err "Missing: .azul-credentials"; ok=false; }
    [ -d "${AZUL_DIR}/azul-app" ]          || { log_err "Missing: azul-app/ directory"; ok=false; }

    case "$section" in
        infra)
            [ -f "${AZUL_DIR}/azul-infra-values.yaml" ]    || { log_err "Missing: azul-infra-values.yaml"; ok=false; }
            [ -d "${AZUL_DIR}/azul-app/infra" ]             || { log_err "Missing: azul-app/infra chart"; ok=false; }
            [ -d "${AZUL_DIR}/charts" ]                     || { log_err "Missing: charts/ (operator tarballs)"; ok=false; }
            [ -f "${AZUL_DIR}/scripts/setup-certs.sh" ]     || { log_err "Missing: scripts/setup-certs.sh"; ok=false; }
            [ -f "${AZUL_DIR}/scripts/setup-keycloak.sh" ]  || { log_err "Missing: scripts/setup-keycloak.sh"; ok=false; }
            ;;
        app)
            [ -f "${AZUL_DIR}/azul-values-core.yaml" ] || { log_err "Missing: azul-values-core.yaml"; ok=false; }
            [ -d "${AZUL_DIR}/azul-app/azul" ]          || { log_err "Missing: azul-app/azul chart"; ok=false; }
            ;;
        plugins)
            [ -f "${AZUL_DIR}/azul-values.yaml" ] || { log_err "Missing: azul-values.yaml"; ok=false; }
            [ -d "${AZUL_DIR}/azul-app/azul" ]     || { log_err "Missing: azul-app/azul chart"; ok=false; }
            ;;
    esac

    local manifest
    manifest=$(manifest_for "$section")
    [ -f "$manifest" ] || { log_err "Missing manifest: $manifest"; ok=false; }

    [ "$ok" = "true" ]
}

verify_section() {
    local section="$1"

    case "$section" in
        infra)
            local total running
            total=$(kubectl get pods -n azul-infra --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
            running=$(kubectl get pods -n azul-infra --no-headers 2>/dev/null | grep -c "Running") || running=0
            log "  azul-infra pods: $running running / $total total"
            local kc_code
            kc_code=$(curl -k -sf -o /dev/null -w '%{http_code}' \
                -H "Host: ${KEYCLOAK_HOST}" https://${CLUSTER_IP}/ 2>/dev/null || echo "000")
            log "  Keycloak: HTTP $kc_code"
            ;;
        app)
            local total running
            total=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
            running=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -c "Running") || running=0
            log "  azul pods: $running running / $total total"
            local web_code
            web_code=$(curl -k -sf -o /dev/null -w '%{http_code}' \
                -H "Host: ${AZUL_HOST}" https://${CLUSTER_IP}/ 2>/dev/null || echo "000")
            log "  Web UI: HTTP $web_code"
            ;;
        plugins)
            local total running
            total=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
            running=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -c "Running") || running=0
            log "  azul pods (with plugins): $running running / $total total"
            ;;
    esac
}

# =================================================================
# UNINSTALL COMMAND
# =================================================================

cmd_uninstall() {
    local section="${1:-all}"
    header "UNINSTALL: $section"

    if [ "$FORCE" != "true" ]; then
        log "This will remove the following:"
        case "$section" in
            plugins) log "  - Downgrade azul release to core-only (remove plugin deployments)" ;;
            app)     log "  - Helm release: azul"; log "  - Namespace: azul (all PVCs and data)" ;;
            infra)   log "  - Helm releases: azul-infra, strimzi, opensearch-operator"
                     log "  - CRDs + namespaces: azul-infra, kafka, opensearch-operator"
                     log "  - CoreDNS azul hosts block" ;;
            all)     log "  - ALL Azul resources (plugins -> app -> infra)" ;;
        esac
        echo ""
        read -rp "Are you sure? Type 'yes' to proceed: " confirm
        if [ "$confirm" != "yes" ]; then
            log "Aborted."
            return 0
        fi
    fi

    case "$section" in
        plugins) uninstall_plugins ;;
        app)     uninstall_app ;;
        infra)   uninstall_infra ;;
        all)     uninstall_plugins; uninstall_app; uninstall_infra ;;
    esac

    log ""
    log "=== Uninstall $section complete ==="
}

uninstall_plugins() {
    log ""
    log "--- Uninstalling plugins (downgrade to core-only) ---"
    if ! helm status azul -n azul >/dev/null 2>&1; then
        log "Helm release 'azul' not found, skipping"
        return 0
    fi
    local core_values="${AZUL_DIR}/azul-values-core.yaml"
    local app_chart="${AZUL_DIR}/azul-app/azul"
    if [ -f "$core_values" ] && [ -d "$app_chart" ]; then
        helm upgrade azul "$app_chart" -n azul -f "$core_values" --timeout 10m
        log "Plugins removed via helm upgrade to core values"
    else
        log_err "Core values or chart not found. Falling back to full uninstall."
        uninstall_app
    fi
}

uninstall_app() {
    log ""
    log "--- Uninstalling azul app ---"
    if helm status azul -n azul >/dev/null 2>&1; then
        helm uninstall azul -n azul --timeout 5m && log "Helm release 'azul' uninstalled" || log_err "Failed to uninstall azul"
    fi
    if kubectl get namespace azul >/dev/null 2>&1; then
        local pvcs
        pvcs=$(kubectl get pvc -n azul -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        for pvc in $pvcs; do
            log "Deleting PVC: azul/$pvc"
            kubectl delete pvc "$pvc" -n azul --timeout=60s 2>/dev/null || true
        done
        log "Deleting namespace: azul"
        kubectl delete namespace azul --timeout=120s 2>/dev/null || true
    fi
}

uninstall_infra() {
    log ""
    log "--- Uninstalling azul infra ---"
    if helm status azul-infra -n azul-infra >/dev/null 2>&1; then
        helm uninstall azul-infra -n azul-infra --timeout 5m && log "azul-infra uninstalled" || log_err "Failed to uninstall azul-infra"
    fi
    if kubectl get namespace azul-infra >/dev/null 2>&1; then
        local pvcs
        pvcs=$(kubectl get pvc -n azul-infra -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        for pvc in $pvcs; do
            log "Deleting PVC: azul-infra/$pvc"
            kubectl delete pvc "$pvc" -n azul-infra --timeout=60s 2>/dev/null || true
        done
        log "Deleting namespace: azul-infra"
        kubectl delete namespace azul-infra --timeout=120s 2>/dev/null || true
    fi

    for rel_ns in "strimzi-kafka-operator:kafka" "opensearch-operator:opensearch-operator"; do
        local rel="${rel_ns%%:*}" ns="${rel_ns##*:}"
        if helm status "$rel" -n "$ns" >/dev/null 2>&1; then
            helm uninstall "$rel" -n "$ns" --timeout 3m && log "$rel uninstalled" || log_err "Failed to uninstall $rel"
        fi
    done

    # Delete CRDs
    for pattern in strimzi.io opensearch; do
        local crds
        crds=$(kubectl get crds -o name 2>/dev/null | grep "$pattern" || true)
        if [ -n "$crds" ]; then
            log "Deleting $pattern CRDs..."
            echo "$crds" | while read -r crd; do kubectl delete "$crd" --timeout=30s 2>/dev/null || true; done
        fi
    done

    for ns in kafka opensearch-operator; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            log "Deleting namespace: $ns"
            kubectl delete namespace "$ns" --timeout=60s 2>/dev/null || true
        fi
    done

    clean_coredns
}

clean_coredns() {
    local corefile
    corefile=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null || true)
    if echo "$corefile" | grep -q "${KEYCLOAK_HOST:-keycloak-azul}"; then
        log "Removing azul hosts block from CoreDNS..."
        local new_corefile
        new_corefile=$(echo "$corefile" | python3 -c "
import sys
content = sys.stdin.read()
lines = content.split('\n')
result = []
skip = False
for line in lines:
    if 'hosts {' in line or 'hosts{' in line:
        block_start = len(result)
        result.append(line)
        skip = True
        continue
    if skip:
        result.append(line)
        if line.strip() == '}':
            block = '\n'.join(result[block_start:])
            if 'azul' in block:
                result = result[:block_start]
            skip = False
        continue
    result.append(line)
output = '\n'.join(result)
while '\n\n\n' in output:
    output = output.replace('\n\n\n', '\n\n')
print(output, end='')
")
        kubectl create configmap coredns -n kube-system \
            --from-literal=Corefile="$new_corefile" \
            --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
        kubectl rollout restart deployment coredns -n kube-system 2>/dev/null || true
        log "CoreDNS cleaned"
    else
        log "No azul hosts block in CoreDNS"
    fi
}

# =================================================================
# STATUS COMMAND
# =================================================================

cmd_status() {
    local section="${1:-all}"
    header "STATUS: $section"

    local sections=()
    case "$section" in
        all) sections=(infra app plugins) ;;
        *)   sections=("$section") ;;
    esac

    log ""
    log "--- Helm Releases ---"
    helm list -n azul-infra 2>/dev/null | head -5 || log "  (none in azul-infra)"
    helm list -n azul 2>/dev/null | head -5 || log "  (none in azul)"
    helm list -n kafka 2>/dev/null | head -5 || log "  (none in kafka)"
    helm list -n opensearch-operator 2>/dev/null | head -5 || log "  (none in opensearch-operator)"

    for s in "${sections[@]}"; do
        log ""
        log "--- Section: $s ---"
        case "$s" in
            infra)
                if kubectl get namespace azul-infra >/dev/null 2>&1; then
                    local total running
                    total=$(kubectl get pods -n azul-infra --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
                    running=$(kubectl get pods -n azul-infra --no-headers 2>/dev/null | grep -c "Running") || running=0
                    log "  azul-infra: $running running / $total total"
                else
                    log "  azul-infra: namespace does not exist"
                fi
                for op_ns in kafka opensearch-operator; do
                    if kubectl get namespace "$op_ns" >/dev/null 2>&1; then
                        local op_pods
                        op_pods=$(kubectl get pods -n "$op_ns" --no-headers 2>/dev/null | wc -l)
                        log "  $op_ns: $op_pods pods"
                    else
                        log "  $op_ns: not deployed"
                    fi
                done
                ;;
            app)
                if kubectl get namespace azul >/dev/null 2>&1; then
                    local core_pods
                    core_pods=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -v "^plugin-" | grep -v "Completed" | wc -l)
                    log "  Core pods: $core_pods"
                else
                    log "  azul: namespace does not exist"
                fi
                ;;
            plugins)
                if kubectl get namespace azul >/dev/null 2>&1; then
                    local plugin_pods total_pods
                    plugin_pods=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep "^plugin-" | wc -l)
                    total_pods=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
                    log "  Plugin pods: $plugin_pods / Total: $total_pods"
                else
                    log "  azul: namespace does not exist"
                fi
                ;;
        esac
    done

    log ""
    log "--- Registry ---"
    if curl -sf --connect-timeout 3 "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
        local repo_count
        repo_count=$(curl -sf "http://${REGISTRY}/v2/_catalog" 2>/dev/null \
            | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('repositories',[])))" 2>/dev/null || echo "0")
        log "  Registry at ${REGISTRY}: $repo_count repositories"
    else
        log "  Registry at ${REGISTRY}: unreachable"
    fi

    log ""
    log "--- File Server ---"
    if curl -sf --connect-timeout 3 "http://${FILESERVER}/" >/dev/null 2>&1; then
        log "  File server at ${FILESERVER}: reachable"
    else
        log "  File server at ${FILESERVER}: unreachable"
    fi
}

# =================================================================
# USAGE
# =================================================================

usage() {
    cat <<'USAGE'
AZUL Deployment Framework

Usage: azul-framework.sh <command> [args] [--force]

Commands:
  sync <service-ip> [port]   Sync files from file server
  validate [section]         Check registry for required images
  push     [section]         Pull upstream images and push to registry
  install  [section]         Full install with pre-checks
  uninstall [section]        Clean uninstall
  status   [section]         Show current state

Sections: infra | app | plugins | all (default: all)

Bootstrap (fresh machine):
  curl -o azul-framework.sh http://<ip>:8888/AZUL/azul-framework.sh
  chmod +x azul-framework.sh
  ./azul-framework.sh sync <service-ip>

Full deploy workflow:
  ./azul-framework.sh sync 192.168.66.41      # 1. Get files
  ./azul-framework.sh validate all             # 2. Check images
  ./azul-framework.sh push all                 # 3. Push missing
  ./azul-framework.sh install infra            # 4. Infrastructure
  ./azul-framework.sh install app              # 5. Application
  ./azul-framework.sh install plugins          # 6. Plugins
  ./azul-framework.sh status all               # 7. Verify
USAGE
    exit 1
}

# =================================================================
# MAIN
# =================================================================

CMD="${1:-}"
SECTION="all"
SYNC_SERVER_IP=""
SYNC_SERVER_PORT=""

# Parse arguments based on command
case "$CMD" in
    sync)
        SYNC_SERVER_IP="${2:-}"
        SYNC_SERVER_PORT="${3:-}"
        ;;
    validate|push|install|uninstall|status)
        SECTION="${2:-all}"
        ;;
esac

# Check for --force flag in any position
for arg in "$@"; do
    [ "$arg" = "--force" ] && FORCE=true
done
[ "$SECTION" = "--force" ] && SECTION="all"

# Initialize log
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
log "--- azul-framework.sh $* ---"

case "$CMD" in
    sync)      cmd_sync ;;
    validate)  cmd_validate "$SECTION" ;;
    push)      cmd_push "$SECTION" ;;
    install)   cmd_install "$SECTION" ;;
    uninstall) cmd_uninstall "$SECTION" ;;
    status)    cmd_status "$SECTION" ;;
    *)         usage ;;
esac
