#!/bin/bash
set -e

LOG_FILE="/logs/batch-seed.log"
MEDIA_ROOT="/data/media"

echo "===================================================" >> "$LOG_FILE"
echo "🕒 Batch Seed Run — $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "===================================================" >> "$LOG_FILE"

seed_category() {
  local cat="$1"
  local path="$MEDIA_ROOT/$cat"
  echo "📂 Scanning $path ..." >> "$LOG_FILE"

  for dir in "$path"/*; do
    if [ -d "$dir" ]; then
      title=$(basename "$dir")
      echo "🎬 [$cat] $title — starting..." >> "$LOG_FILE"
      python3 /app/seedlink.py --title "$title" --dir "$dir" --cat "$cat" >> "$LOG_FILE" 2>&1
      echo "---------------------------------------------------" >> "$LOG_FILE"
      sleep 5
    fi
  done
}

seed_category "movies"
seed_category "tv"

echo "✅ Batch seed run completed — $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"



# Run the batch seeder
# docker exec -it seedlink /app/batch-seed.sh

#Tail logs:
# docker exec -it seedlink tail -f /logs/batch-seed.log