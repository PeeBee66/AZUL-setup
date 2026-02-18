#!/usr/bin/env bash
# =================================================================
# AZUL Deployment Framework
# =================================================================
# Wraps the existing Helm-based AZUL deployment with:
#   - File server sync (from internal nginx at port 8888)
#   - Container registry validation (private registry at port 5000)
#   - Install/uninstall for each of the 3 stages
#
# Usage:
#   azul-framework.sh sync                    Sync files from file server
#   azul-framework.sh validate [section]      Check registry for required images
#   azul-framework.sh push     [section]      Pull upstream images → push to registry
#   azul-framework.sh install  [section]      Full install with pre-checks
#   azul-framework.sh uninstall [section]     Clean uninstall
#   azul-framework.sh status   [section]      Show current state
#
# Sections: infra | app | plugins | all
#
# Compatible with: Ubuntu 22.04+, RHEL 9+
# =================================================================
set -euo pipefail

# Source central config — search multiple locations so the script works
# both from the standard layout (scripts/azul-framework.sh) and when
# downloaded standalone to a flat directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/../azul.conf" ]; then
    source "${SCRIPT_DIR}/../azul.conf"
elif [ -f "${SCRIPT_DIR}/azul.conf" ]; then
    source "${SCRIPT_DIR}/azul.conf"
elif [ -f "${AZUL_DIR:-/data/AZUL}/azul.conf" ]; then
    source "${AZUL_DIR:-/data/AZUL}/azul.conf"
else
    echo "ERROR: azul.conf not found. Place it next to this script or in the parent directory."
    exit 1
fi

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
    echo "$msg" >> "$LOG_FILE"
}

log_err() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE"
}

die() {
    log_err "$*"
    exit 1
}

# Print section header
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
# IMAGE MANIFEST HELPERS
# =================================================================

# Read image manifest file, stripping comments and blank lines
read_manifest() {
    local file="$1"
    [ -f "$file" ] || die "Manifest not found: $file"
    grep -v '^#' "$file" | grep -v '^$'
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

# Parse image into registry-compatible parts
# Input:  docker.io/asdazul/dispatcher:9.0.0@sha256:...
# Output: repo=asdazul/dispatcher tag=9.0.0
parse_image() {
    local image="$1"

    # Strip digest (@sha256:...) if present
    local no_digest="${image%%@*}"

    # Strip registry prefix to get repo:tag
    local repo_tag
    case "$no_digest" in
        docker.io/*)       repo_tag="${no_digest#docker.io/}" ;;
        quay.io/*)         repo_tag="${no_digest#quay.io/}" ;;
        gcr.io/*)          repo_tag="${no_digest#gcr.io/}" ;;
        ghcr.io/*)         repo_tag="${no_digest#ghcr.io/}" ;;
        registry.k8s.io/*) repo_tag="${no_digest#registry.k8s.io/}" ;;
        */*:*)             repo_tag="$no_digest" ;;
        *)                 repo_tag="library/$no_digest" ;;
    esac

    # Split into repo and tag
    PARSED_REPO="${repo_tag%%:*}"
    PARSED_TAG="${repo_tag##*:}"
}

# =================================================================
# REGISTRY FUNCTIONS
# =================================================================

# Check if a single image exists in the private registry
# Returns 0 if found, 1 if missing
check_image_in_registry() {
    local image="$1"
    parse_image "$image"

    local url="http://${REGISTRY}/v2/${PARSED_REPO}/tags/list"
    local response
    response=$(curl -sf "$url" 2>/dev/null) || return 1

    # Check if our tag is in the response
    echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tags = data.get('tags', []) or []
sys.exit(0 if '${PARSED_TAG}' in tags else 1)
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

    while IFS= read -r image; do
        total=$((total + 1))
        if check_image_in_registry "$image"; then
            found=$((found + 1))
        else
            missing=$((missing + 1))
            missing_list="${missing_list}  - ${image}\n"
        fi
    done < <(read_manifest "$manifest")

    log "  Section: $section"
    log "  Total: $total | Found: $found | Missing: $missing"

    if [ "$missing" -gt 0 ]; then
        log ""
        log "  Missing images:"
        echo -e "$missing_list" | while IFS= read -r line; do
            [ -n "$line" ] && log "$line"
        done
        return 1
    fi

    log "  All $section images present in registry."
    return 0
}

# Push a single image to the private registry
push_single_image() {
    local image="$1"
    parse_image "$image"

    local local_tag="${REGISTRY}/${PARSED_REPO}:${PARSED_TAG}"

    log "  Pulling: $image"
    if ! $CONTAINER_RT pull "$image" 2>>"$LOG_FILE"; then
        log_err "  Failed to pull: $image"
        return 1
    fi

    log "  Tagging: $local_tag"
    $CONTAINER_RT tag "$image" "$local_tag" 2>>"$LOG_FILE"

    log "  Pushing: $local_tag"
    if ! $CONTAINER_RT push "$local_tag" 2>>"$LOG_FILE"; then
        log_err "  Failed to push: $local_tag"
        return 1
    fi

    # Verify push
    if check_image_in_registry "$image"; then
        log "  OK: $PARSED_REPO:$PARSED_TAG"
    else
        log_err "  Push verification failed: $PARSED_REPO:$PARSED_TAG"
        return 1
    fi
}

# Push all missing images for a section
push_section() {
    local section="$1"
    local manifest
    manifest=$(manifest_for "$section")

    log "Checking $section images for push to ${REGISTRY}..."

    local to_push=()
    while IFS= read -r image; do
        if ! check_image_in_registry "$image"; then
            to_push+=("$image")
        fi
    done < <(read_manifest "$manifest")

    if [ ${#to_push[@]} -eq 0 ]; then
        log "All $section images already in registry. Nothing to push."
        return 0
    fi

    log "${#to_push[@]} images need to be pushed for $section:"
    for img in "${to_push[@]}"; do
        parse_image "$img"
        log "  - $PARSED_REPO:$PARSED_TAG"
    done

    if [ "$FORCE" != "true" ]; then
        echo ""
        read -rp "Download and push ${#to_push[@]} images to registry? (y/n): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            log "Push cancelled by user."
            return 1
        fi
    fi

    log ""
    local pushed=0 failed=0
    for img in "${to_push[@]}"; do
        if push_single_image "$img"; then
            pushed=$((pushed + 1))
        else
            failed=$((failed + 1))
        fi
    done

    log ""
    log "Push complete: $pushed succeeded, $failed failed (of ${#to_push[@]} total)"
    [ "$failed" -eq 0 ] && return 0 || return 1
}

# =================================================================
# FILE SERVER SYNC
# =================================================================

# Recursive directory download using curl (fallback when wget unavailable)
sync_with_curl() {
    local dest="$1" url="$2" prefix="$3"

    mkdir -p "${dest}/${prefix}"

    # Get directory listing, extract href links
    local listing
    listing=$(curl -sf "$url" 2>/dev/null) || return 1

    # Parse hrefs from nginx autoindex page
    local links
    links=$(echo "$listing" | grep -oP 'href="\K[^"]+' | grep -v '^\.\.' | grep -v '^/$')

    for link in $links; do
        if [[ "$link" == */ ]]; then
            # Directory — recurse
            sync_with_curl "$dest" "${url}${link}" "${prefix}/${link%/}"
        else
            # File — download
            curl -sf -o "${dest}/${prefix}/${link}" "${url}${link}" 2>>"$LOG_FILE" || \
                log_err "Failed to download: ${url}${link}"
        fi
    done
}

cmd_sync() {
    header "FILE SERVER SYNC"

    local fileserver_url="http://${FILESERVER}/AZUL/"

    # 1. Health check
    log "Checking file server at ${fileserver_url}..."
    if ! curl -sf --connect-timeout 5 "${fileserver_url}" >/dev/null 2>&1; then
        die "File server unreachable at ${fileserver_url}"
    fi
    log "File server is reachable."

    # 2. Download/update files
    log "Syncing files from file server..."
    local staging_dir
    staging_dir=$(mktemp -d /tmp/azul-sync.XXXXXX)
    trap "rm -rf '$staging_dir'" EXIT

    # Use wget mirror mode to get the full tree
    if command -v wget >/dev/null 2>&1; then
        wget -q --mirror --no-parent --no-host-directories \
            --reject "index.html*" \
            --cut-dirs=0 \
            -P "$staging_dir" \
            "${fileserver_url}" 2>>"$LOG_FILE" || die "wget sync failed"
    elif command -v curl >/dev/null 2>&1; then
        # curl fallback: parse directory listing and download files recursively
        log "wget not found, using curl fallback (install wget for better sync: dnf install wget)"
        sync_with_curl "$staging_dir" "${fileserver_url}" "AZUL"
    else
        die "Neither wget nor curl found. Install wget: dnf install wget (RHEL) or apt install wget (Ubuntu)"
    fi

    # 3. Validate structure
    log "Validating downloaded structure..."
    local required_dirs=("AZUL/azul-app" "AZUL/scripts")
    local required_files=("AZUL/azul-infra-values.yaml" "AZUL/azul-values.yaml" "AZUL/images-infra.txt")
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

    # 4. Copy files, preserving sensitive user files
    log "Copying synced files to ${AZUL_DIR}..."
    local protected_files=(".azul-credentials" "azul-infra-values.yaml" "azul-values.yaml" "azul-values-core.yaml" "framework.log")

    # Build rsync exclude list
    local rsync_excludes=()
    for pf in "${protected_files[@]}"; do
        rsync_excludes+=(--exclude "$pf")
    done

    if command -v rsync >/dev/null 2>&1; then
        rsync -a "${rsync_excludes[@]}" "${staging_dir}/AZUL/" "${AZUL_DIR}/" 2>>"$LOG_FILE"
    else
        # Fallback: cp with manual protection
        for pf in "${protected_files[@]}"; do
            [ -f "${AZUL_DIR}/${pf}" ] && cp "${AZUL_DIR}/${pf}" "/tmp/azul-protect-${pf}" 2>/dev/null || true
        done
        cp -rn "${staging_dir}/AZUL/"* "${AZUL_DIR}/" 2>>"$LOG_FILE" || true
        for pf in "${protected_files[@]}"; do
            [ -f "/tmp/azul-protect-${pf}" ] && mv "/tmp/azul-protect-${pf}" "${AZUL_DIR}/${pf}" 2>/dev/null || true
        done
    fi

    # Make scripts executable
    chmod +x "${AZUL_DIR}/scripts/"*.sh 2>/dev/null || true

    log "Sync complete."
    log ""
    log "Protected files (NOT overwritten):"
    for pf in "${protected_files[@]}"; do
        [ -f "${AZUL_DIR}/${pf}" ] && log "  - $pf"
    done

    trap - EXIT
    rm -rf "$staging_dir"
}

# =================================================================
# VALIDATE COMMAND
# =================================================================

cmd_validate() {
    local section="${1:-all}"
    header "REGISTRY VALIDATION: $section"

    # Check registry is reachable
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

    # Check registry is reachable
    if ! curl -sf --connect-timeout 5 "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
        die "Registry unreachable at http://${REGISTRY}"
    fi

    # Check container runtime is available
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

    # Print access info after install completes
    print_access_info
}

install_section() {
    local section="$1"
    log ""
    log "--- Installing section: $section ---"

    # Phase 1: Verify files exist
    log "Phase 1: Checking required files..."
    if ! preflight_files "$section"; then
        die "File pre-flight check failed for $section. Run: $0 sync"
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

# Check that required files exist for a section
preflight_files() {
    local section="$1"
    local ok=true

    # Common checks
    [ -f "${AZUL_DIR}/.azul-credentials" ]      || { log_err "Missing: .azul-credentials"; ok=false; }
    [ -d "${AZUL_DIR}/azul-app" ]                || { log_err "Missing: azul-app/ directory"; ok=false; }

    case "$section" in
        infra)
            [ -f "${AZUL_DIR}/azul-infra-values.yaml" ]   || { log_err "Missing: azul-infra-values.yaml"; ok=false; }
            [ -d "${AZUL_DIR}/azul-app/infra" ]            || { log_err "Missing: azul-app/infra chart"; ok=false; }
            [ -d "${AZUL_DIR}/charts" ]                    || { log_err "Missing: charts/ (operator tarballs)"; ok=false; }
            [ -f "${AZUL_DIR}/scripts/setup-certs.sh" ]    || { log_err "Missing: scripts/setup-certs.sh"; ok=false; }
            [ -f "${AZUL_DIR}/setup-keycloak.sh" ]         || { log_err "Missing: setup-keycloak.sh"; ok=false; }
            ;;
        app)
            [ -f "${AZUL_DIR}/azul-values-core.yaml" ]    || { log_err "Missing: azul-values-core.yaml"; ok=false; }
            [ -d "${AZUL_DIR}/azul-app/azul" ]             || { log_err "Missing: azul-app/azul chart"; ok=false; }
            ;;
        plugins)
            [ -f "${AZUL_DIR}/azul-values.yaml" ]          || { log_err "Missing: azul-values.yaml"; ok=false; }
            [ -d "${AZUL_DIR}/azul-app/azul" ]             || { log_err "Missing: azul-app/azul chart"; ok=false; }
            ;;
    esac

    # Check image manifest
    local manifest
    manifest=$(manifest_for "$section")
    [ -f "$manifest" ] || { log_err "Missing manifest: $manifest"; ok=false; }

    [ "$ok" = "true" ]
}

# Post-install verification
verify_section() {
    local section="$1"

    case "$section" in
        infra)
            local ns="azul-infra"
            local total
            total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
            local running
            running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running") || running=0
            log "  azul-infra pods: $running running / $total total"

            # Quick endpoint checks
            local kc_code
            kc_code=$(curl -k -sf -o /dev/null -w '%{http_code}' \
                -H "Host: ${KEYCLOAK_HOST}" https://${CLUSTER_IP}/ 2>/dev/null || echo "000")
            log "  Keycloak: HTTP $kc_code"
            ;;
        app)
            local total
            total=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
            local running
            running=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -c "Running") || running=0
            log "  azul pods: $running running / $total total"

            local web_code
            web_code=$(curl -k -sf -o /dev/null -w '%{http_code}' \
                -H "Host: ${AZUL_HOST}" https://${CLUSTER_IP}/ 2>/dev/null || echo "000")
            log "  Web UI: HTTP $web_code"
            ;;
        plugins)
            local total
            total=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
            local running
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
            plugins)
                log "  - Downgrade azul release to core-only (remove plugin deployments)"
                ;;
            app)
                log "  - Helm release: azul"
                log "  - Namespace: azul (all PVCs and data)"
                ;;
            infra)
                log "  - Helm release: azul-infra"
                log "  - Operators: strimzi-kafka-operator, opensearch-operator"
                log "  - CRDs: Strimzi, OpenSearch"
                log "  - Namespaces: azul-infra, kafka, opensearch-operator"
                log "  - CoreDNS azul hosts block"
                ;;
            all)
                log "  - ALL Azul resources (plugins → app → infra)"
                ;;
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
        all)
            uninstall_plugins
            uninstall_app
            uninstall_infra
            ;;
    esac

    log ""
    log "=== Uninstall $section complete ==="
}

uninstall_plugins() {
    log ""
    log "--- Uninstalling plugins (downgrade to core-only) ---"

    if ! helm status azul -n azul >/dev/null 2>&1; then
        log "Helm release 'azul' not found, skipping plugins uninstall"
        return 0
    fi

    local core_values="${AZUL_DIR}/azul-values-core.yaml"
    local app_chart="${AZUL_DIR}/azul-app/azul"

    if [ -f "$core_values" ] && [ -d "$app_chart" ]; then
        log "Downgrading azul to core-only values (disables plugins)..."
        helm upgrade azul "$app_chart" -n azul -f "$core_values" --timeout 10m
        log "Plugins removed via helm upgrade to core values"

        # Clean up orphaned plugin pods
        log "Cleaning up plugin pods..."
        local plugin_deploys
        plugin_deploys=$(kubectl get deployments -n azul --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
            | grep -E "^plugin-" || true)
        if [ -n "$plugin_deploys" ]; then
            log "WARNING: ${plugin_deploys} plugin deployments still exist after downgrade"
        fi
    else
        log_err "Core values or chart not found. Cannot downgrade."
        log "  Falling back to full uninstall of azul release..."
        uninstall_app
    fi
}

uninstall_app() {
    log ""
    log "--- Uninstalling azul app ---"

    if helm status azul -n azul >/dev/null 2>&1; then
        if helm uninstall azul -n azul --timeout 5m; then
            log "Helm release 'azul' uninstalled"
        else
            log_err "Failed to uninstall azul release"
        fi
    else
        log "Helm release 'azul' not found, skipping"
    fi

    # Delete PVCs
    if kubectl get namespace azul >/dev/null 2>&1; then
        local pvcs
        pvcs=$(kubectl get pvc -n azul -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        if [ -n "$pvcs" ]; then
            for pvc in $pvcs; do
                log "Deleting PVC: azul/$pvc"
                kubectl delete pvc "$pvc" -n azul --timeout=60s 2>/dev/null || true
            done
        fi

        log "Deleting namespace: azul"
        kubectl delete namespace azul --timeout=120s 2>/dev/null || true
    else
        log "Namespace azul not found, skipping"
    fi
}

uninstall_infra() {
    log ""
    log "--- Uninstalling azul infra ---"

    # Uninstall azul-infra helm release
    if helm status azul-infra -n azul-infra >/dev/null 2>&1; then
        if helm uninstall azul-infra -n azul-infra --timeout 5m; then
            log "Helm release 'azul-infra' uninstalled"
        else
            log_err "Failed to uninstall azul-infra release"
        fi
    else
        log "Helm release 'azul-infra' not found, skipping"
    fi

    # Delete PVCs in azul-infra
    if kubectl get namespace azul-infra >/dev/null 2>&1; then
        local pvcs
        pvcs=$(kubectl get pvc -n azul-infra -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        if [ -n "$pvcs" ]; then
            for pvc in $pvcs; do
                log "Deleting PVC: azul-infra/$pvc"
                kubectl delete pvc "$pvc" -n azul-infra --timeout=60s 2>/dev/null || true
            done
        fi

        log "Deleting namespace: azul-infra"
        kubectl delete namespace azul-infra --timeout=120s 2>/dev/null || true
    else
        log "Namespace azul-infra not found, skipping"
    fi

    # Uninstall operators
    if helm status strimzi-kafka-operator -n kafka >/dev/null 2>&1; then
        helm uninstall strimzi-kafka-operator -n kafka --timeout 3m && \
            log "Strimzi operator uninstalled" || \
            log_err "Failed to uninstall Strimzi"
    else
        log "Strimzi operator not found, skipping"
    fi

    if helm status opensearch-operator -n opensearch-operator >/dev/null 2>&1; then
        helm uninstall opensearch-operator -n opensearch-operator --timeout 3m && \
            log "OpenSearch operator uninstalled" || \
            log_err "Failed to uninstall OpenSearch operator"
    else
        log "OpenSearch operator not found, skipping"
    fi

    # Delete CRDs
    local strimzi_crds
    strimzi_crds=$(kubectl get crds -o name 2>/dev/null | grep "strimzi.io" || true)
    if [ -n "$strimzi_crds" ]; then
        log "Deleting Strimzi CRDs..."
        echo "$strimzi_crds" | while read -r crd; do
            kubectl delete "$crd" --timeout=30s 2>/dev/null || true
        done
    fi

    local os_crds
    os_crds=$(kubectl get crds -o name 2>/dev/null | grep "opensearch" || true)
    if [ -n "$os_crds" ]; then
        log "Deleting OpenSearch CRDs..."
        echo "$os_crds" | while read -r crd; do
            kubectl delete "$crd" --timeout=30s 2>/dev/null || true
        done
    fi

    # Delete operator namespaces
    for ns in kafka opensearch-operator; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            log "Deleting namespace: $ns"
            kubectl delete namespace "$ns" --timeout=60s 2>/dev/null || true
        fi
    done

    # Clean CoreDNS
    clean_coredns
}

clean_coredns() {
    local corefile
    corefile=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null || true)

    if echo "$corefile" | grep -q "${KEYCLOAK_HOST}"; then
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

    # Helm releases
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
                log "Namespace: azul-infra"
                if kubectl get namespace azul-infra >/dev/null 2>&1; then
                    local total running
                    total=$(kubectl get pods -n azul-infra --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
                    running=$(kubectl get pods -n azul-infra --no-headers 2>/dev/null | grep -c "Running") || running=0
                    log "  Pods: $running running / $total total"
                    kubectl get pods -n azul-infra --no-headers 2>/dev/null | while read -r line; do
                        log "    $line"
                    done
                else
                    log "  Namespace does not exist"
                fi

                log "Operators:"
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
                log "Namespace: azul"
                if kubectl get namespace azul >/dev/null 2>&1; then
                    local core_pods
                    core_pods=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -v "^plugin-" | grep -v "Completed" | wc -l)
                    log "  Core pods: $core_pods"
                else
                    log "  Namespace does not exist"
                fi
                ;;

            plugins)
                log "Namespace: azul (plugin deployments)"
                if kubectl get namespace azul >/dev/null 2>&1; then
                    local plugin_pods
                    plugin_pods=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep "^plugin-" | wc -l)
                    local total_pods
                    total_pods=$(kubectl get pods -n azul --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
                    log "  Plugin pods: $plugin_pods"
                    log "  Total pods: $total_pods"
                else
                    log "  Namespace does not exist"
                fi
                ;;
        esac
    done

    # Registry status
    log ""
    log "--- Registry ---"
    if curl -sf --connect-timeout 3 "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
        local catalog
        catalog=$(curl -sf "http://${REGISTRY}/v2/_catalog" 2>/dev/null || echo '{"repositories":[]}')
        local repo_count
        repo_count=$(echo "$catalog" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('repositories',[])))" 2>/dev/null || echo "0")
        log "  Registry at ${REGISTRY}: $repo_count repositories"
    else
        log "  Registry at ${REGISTRY}: unreachable"
    fi

    # File server status
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
    echo "AZUL Deployment Framework"
    echo ""
    echo "Usage: $0 <command> [section] [--force]"
    echo ""
    echo "Commands:"
    echo "  sync                    Sync files from file server (${FILESERVER})"
    echo "  validate [section]      Check registry for required images"
    echo "  push     [section]      Pull upstream images and push to registry"
    echo "  install  [section]      Full install with pre-checks"
    echo "  uninstall [section]     Clean uninstall"
    echo "  status   [section]      Show current state"
    echo ""
    echo "Sections: infra | app | plugins | all (default: all)"
    echo ""
    echo "Options:"
    echo "  --force     Skip confirmation prompts"
    echo ""
    echo "Examples:"
    echo ""
    echo "  # Sync files from file server"
    echo "  $0 sync"
    echo ""
    echo "  # Validate registry images"
    echo "  $0 validate all"
    echo "  $0 validate infra"
    echo "  $0 validate app"
    echo "  $0 validate plugins"
    echo ""
    echo "  # Push images to private registry"
    echo "  $0 push all"
    echo "  $0 push infra"
    echo "  $0 push app"
    echo "  $0 push plugins"
    echo "  $0 push all --force"
    echo ""
    echo "  # Install (pre-checks + deploy)"
    echo "  $0 install all"
    echo "  $0 install infra"
    echo "  $0 install app"
    echo "  $0 install plugins"
    echo "  $0 install all --force"
    echo ""
    echo "  # Uninstall"
    echo "  $0 uninstall all"
    echo "  $0 uninstall infra"
    echo "  $0 uninstall app"
    echo "  $0 uninstall plugins"
    echo "  $0 uninstall all --force"
    echo ""
    echo "  # Status"
    echo "  $0 status"
    echo "  $0 status all"
    echo "  $0 status infra"
    echo "  $0 status app"
    echo "  $0 status plugins"
    echo ""
    echo "  # Typical full deploy workflow"
    echo "  $0 sync                  # 1. Get latest files"
    echo "  $0 validate all          # 2. Check images"
    echo "  $0 push all              # 3. Push missing images"
    echo "  $0 install infra         # 4. Deploy infrastructure"
    echo "  $0 install app           # 5. Deploy application"
    echo "  $0 install plugins       # 6. Deploy plugins"
    echo "  $0 status all            # 7. Verify everything"
    exit 1
}

# =================================================================
# MAIN
# =================================================================

# Parse arguments
CMD="${1:-}"
SECTION="${2:-all}"

# Check for --force flag in any position
for arg in "$@"; do
    [ "$arg" = "--force" ] && FORCE=true
done

# Adjust SECTION if it's --force
[ "$SECTION" = "--force" ] && SECTION="all"

# Initialize log
mkdir -p "$(dirname "$LOG_FILE")"
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
