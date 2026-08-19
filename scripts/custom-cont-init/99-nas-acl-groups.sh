#!/usr/bin/with-contenv bash
# ---------------------------------------------------------------------------
# NAS ACL group reconciler  (LinuxServer.io /custom-cont-init.d hook)
#
# UGOS enforces a proprietary ACL stored in the `system.ugacl_self` xattr that
# OVERRIDES the POSIX mode: a directory can be 0777 and still return EACCES.
# The ACL denies processes whose group set contains the UGOS "everyone" group,
# and LinuxServer images happen to put `abc` in a group with that same GID.
#
# Rather than hardcoding a GID (firmware updates renumber them), this probes
# the real mounts and drops only the supplementary groups that actually block
# writes, keeping every group that does no harm. If it cannot fix things it
# restores the original membership and logs loudly instead of guessing.
# ---------------------------------------------------------------------------
set -uo pipefail

APP_USER="abc"
PGID="${PGID:-100}"
PROBE=".nas-acl-probe-$$"

log() { echo "[nas-acl] $*"; }

# Run a command as the app user, honouring the current /etc/group membership.
as_app_user() {
    if command -v s6-setuidgid >/dev/null 2>&1; then
        s6-setuidgid "$APP_USER" "$@"
    else
        su -s /bin/sh "$APP_USER" -c "$(printf '%q ' "$@")"
    fi
}

group_name() { getent group "$1" | cut -d: -f1; }

drop_group() {
    gpasswd -d "$APP_USER" "$1" >/dev/null 2>&1 ||
        delgroup "$APP_USER" "$1" >/dev/null 2>&1
}

add_group() {
    gpasswd -a "$APP_USER" "$1" >/dev/null 2>&1 ||
        addgroup "$APP_USER" "$1" >/dev/null 2>&1
}

# Which paths must be writable?
# Override with ACL_PROBE_PATHS="/media /downloads" in the compose environment.
discover_paths() {
    if [ -n "${ACL_PROBE_PATHS:-}" ]; then
        printf '%s\n' ${ACL_PROBE_PATHS}
        return
    fi
    # Bind-mounted, read-write, non-system mount points.
    awk '$2 ~ /^\/[^\/]+(\/[^\/]+)?$/ && $4 ~ /(^|,)rw(,|$)/ {print $2}' /proc/self/mounts |
        grep -Ev '^/(config|proc|sys|dev|run|tmp|etc|var|usr|app|init|package|command|bin|sbin|lib|opt|root|home)(/|$)' |
        grep -Ev 'cont-init|cont-services|pia-shared' |
        sort -u
}

# Can the app user write to every probe path with the current group membership?
writable() {
    local path rc=0
    for path in "${PATHS[@]}"; do
        if as_app_user mkdir "$path/$PROBE" 2>/dev/null; then
            as_app_user rmdir "$path/$PROBE" 2>/dev/null
        else
            rc=1
        fi
    done
    return $rc
}

mapfile -t PATHS < <(discover_paths)
if [ "${#PATHS[@]}" -eq 0 ]; then
    log "no data mounts detected, nothing to check"
    exit 0
fi
log "probing writability of: ${PATHS[*]}"

if writable; then
    log "all mounts writable as ${APP_USER}, no changes needed"
    exit 0
fi

log "write denied despite POSIX mode - suspected NAS ACL, reconciling groups"

# Supplementary groups only; the primary group is never touched.
mapfile -t SUPP < <(id -G "$APP_USER" | tr ' ' '\n' | grep -vx "$PGID" | sort -u)

DROPPED=()
for gid in "${SUPP[@]:-}"; do
    [ -n "$gid" ] || continue
    name="$(group_name "$gid")"
    [ -n "$name" ] || continue
    drop_group "$name" || continue
    DROPPED+=("$name")
    log "retrying without group ${name} (gid ${gid})"
    writable && break
done

if ! writable; then
    for name in "${DROPPED[@]:-}"; do
        [ -n "$name" ] && add_group "$name"
    done
    log "!! Still denied with no supplementary groups - original membership restored."
    log "!! The NAS ACL denies uid $(id -u "$APP_USER")/gid ${PGID} outright, which"
    log "!! cannot be fixed from inside the container. Grant that user read/write on"
    log "!! the share in the UGOS control panel. Inspect the ACL on the host with:"
    log "!!     getfattr -d -m - <host path>"
    exit 0
fi

# Put back any group that was not actually the culprit.
for name in "${DROPPED[@]:-}"; do
    [ -n "$name" ] || continue
    add_group "$name"
    if ! writable; then
        drop_group "$name"
        log "dropped ${APP_USER} from group ${name} - blocked by NAS ACL"
    fi
done

log "resolved - all mounts writable as ${APP_USER} (groups: $(id -G "$APP_USER" | tr ' ' ','))"
