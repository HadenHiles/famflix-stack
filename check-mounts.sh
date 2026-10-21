#!/usr/bin/env bash
# ------------------------------------------------------------
# FamFlix Mount Access Checker (Enhanced Edition)
# ------------------------------------------------------------
# Checks expected mounts, verifies subdirectory visibility for
# /media/movies and /media/tv, and tests write permissions.
# ------------------------------------------------------------

set -euo pipefail
TESTFILE="famflix_testfile.txt"
PRINT_PERMS=true   # Set false for shorter output
LIST_DEPTH=2       # How many levels of files/folders to show

# --- Container Definitions ----------------------------------

declare -A PATHS WRITE

PATHS["qbittorrent"]="/data /config"
WRITE["qbittorrent"]="/data/downloads/qbittorrent/complete"

PATHS["sabnzbd"]="/data /config"
WRITE["sabnzbd"]="/data/downloads/sab/complete"

PATHS["sonarr"]="/data /config"
WRITE["sonarr"]="/data/downloads"

PATHS["radarr"]="/data /config"
WRITE["radarr"]="/data/downloads"

PATHS["bazarr"]="/media /movies /tv /config"
WRITE["bazarr"]="/config"

PATHS["prowlarr"]="/config"
WRITE["prowlarr"]=""

PATHS["unmanic"]="/config /media /library/movies /library/tv /library/watch"
WRITE["unmanic"]="/library/watch"

PATHS["jellyseerr"]="/app/config"
WRITE["jellyseerr"]=""

PATHS["maintainerr"]="/opt/data"
WRITE["maintainerr"]="/opt/data"

PATHS["tautulli"]="/config /logs"
WRITE["tautulli"]="/config"

# ------------------------------------------------------------

echo "🔍 Starting container mount access check..."

for c in "${!PATHS[@]}"; do
  echo ""
  echo "▶️ Checking $c ..."
  if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
    echo "⚠️ Container $c not running or missing, skipping."
    continue
  fi

  # --- Base path checks ---
  for p in ${PATHS[$c]}; do
    echo "📂 $p:"
    if $PRINT_PERMS; then
      docker exec "$c" sh -c "ls -ld $p 2>/dev/null || echo '❌ Missing $p'" || true
    else
      docker exec "$c" sh -c "[ -e $p ] && echo '✅ Exists' || echo '❌ Missing $p'" || true
    fi
  done

  # --- Media subdirectory visibility checks ---
  for sub in /media/movies /media/tv; do
    if docker exec "$c" sh -c "[ -d $sub ]"; then
      echo "🔎 Listing first few items in $sub (depth=$LIST_DEPTH):"
      docker exec "$c" sh -c "find $sub -maxdepth $LIST_DEPTH -type f | head -n 5 2>/dev/null || echo '(no files found)'"
    fi
  done

  # --- Write test ---
  for w in ${WRITE[$c]}; do
    [[ -z "$w" ]] && continue
    echo "🧪 Testing write in $w ..."
    docker exec "$c" sh -c "echo 'hello from $c' > $w/${TESTFILE} 2>/dev/null && echo '✅ Write OK' || echo '❌ Write failed to $w'" || true
  done
done

# --- Cleanup ---
echo ""
echo "🧹 Cleaning up test files..."
for c in "${!WRITE[@]}"; do
  for w in ${WRITE[$c]}; do
    [[ -z "$w" ]] && continue
    docker exec "$c" sh -c "rm -f $w/${TESTFILE}" >/dev/null 2>&1 || true
  done
done

echo ""
echo "✅ Mount & file visibility test complete."