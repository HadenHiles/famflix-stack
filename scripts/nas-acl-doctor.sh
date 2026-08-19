#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# NAS ACL doctor - verifies the stack can actually write to media/downloads.
#
# Background: UGOS stores a proprietary ACL in the `system.ugacl_self` xattr
# which overrides the POSIX mode. A UGOS firmware update or a permission change
# in the control panel can re-apply it to a share and silently break every
# import and download while `ls -l` still shows 0777.
#
# Run standalone (`scripts/nas-acl-doctor.sh`) or via `famflix.sh start`.
# Exits non-zero if any container cannot write to its data mounts.
# ---------------------------------------------------------------------------
set -uo pipefail

STACK_PATH="${STACK_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Containers that must be able to write to media/downloads, and the in-container
# paths they need. Add new services here as the stack grows.
declare -A TARGETS=(
    [sonarr]="/media /downloads /downloads-sab"
    [radarr]="/media /downloads /downloads-sab"
    [bazarr]="/media"
    [sabnzbd]="/media /downloads"
    [qbittorrent]="/downloads/complete /downloads/incomplete"
)

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }

failures=0
acl_paths=()

# --- 1. Report which host paths carry the UGOS ACL --------------------------
if [ -f "$STACK_PATH/.env" ]; then
    # shellcheck disable=SC1091
    set -a; source "$STACK_PATH/.env"; set +a
fi

for host_path in "${MEDIA_BASE:-}" "${SAB_DOWNLOAD_BASE:-}" "${QBIT_DOWNLOAD_BASE:-}"; do
    [ -n "$host_path" ] && [ -d "$host_path" ] || continue
    if getfattr -n system.ugacl_self "$host_path" >/dev/null 2>&1; then
        acl_paths+=("$host_path")
    fi
done

if [ "${#acl_paths[@]}" -gt 0 ]; then
    warn "UGOS ACL (system.ugacl_self) present on: ${acl_paths[*]}"
    warn "  POSIX permissions are NOT authoritative on these paths."
fi

# --- 2. Prove each container can actually write -----------------------------
for container in "${!TARGETS[@]}"; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
        warn "SKIP  $container (not deployed)"
        continue
    fi

    bad=""
    for path in ${TARGETS[$container]}; do
        probe="$path/.acl-doctor-$$"
        if ! docker exec -u abc "$container" sh -c "mkdir '$probe' && rmdir '$probe'" >/dev/null 2>&1; then
            bad="$bad $path"
        fi
    done

    if [ -z "$bad" ]; then
        green "OK    $container"
    else
        red   "FAIL  $container cannot write:$bad"
        failures=$((failures + 1))
    fi
done

# --- 3. Actionable remediation ----------------------------------------------
if [ "$failures" -gt 0 ]; then
    echo
    red "================ NAS PERMISSION PROBLEM ================"
    echo "Symptoms this causes: Sonarr/Radarr imports silently fail, manual import"
    echo "does nothing, and no new downloads start (queues look stalled)."
    echo
    echo "Most likely cause: a UGOS firmware update or a control-panel permission"
    echo "change re-applied the 'system.ugacl_self' ACL, which denies the group the"
    echo "container user belongs to - even though the directory mode reads 0777."
    echo
    echo "Try, in order:"
    echo "  1. docker compose up -d --force-recreate ${!TARGETS[*]}"
    echo "     (re-runs scripts/custom-cont-init/99-nas-acl-groups.sh, which drops"
    echo "      the offending group automatically)"
    echo "  2. Inspect the ACL:   getfattr -d -m - \"\${MEDIA_BASE}\""
    echo "  3. Compare group set: docker exec -u abc sonarr id -G"
    echo "  4. If it persists, open the UGOS control panel and grant the share"
    echo "     read/write for uid ${PUID:-1000} / gid ${PGID:-100}."
    echo
    echo "Container-side detail:  docker logs sonarr 2>&1 | grep nas-acl"
    red "========================================================"
    exit 1
fi

green "NAS ACL check passed - all containers can write to their data mounts."
