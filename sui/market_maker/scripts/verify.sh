#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."

# This entire foreground verification holds one host-wide compiler slot.
heavy_slot_acquired=0
for heavy_lock_path in \
  /home/ubuntu/.cache/codex-heavy-task.lock \
  /home/ubuntu/.cache/codex-heavy-task-2.lock \
  /home/ubuntu/.cache/codex-heavy-task-3.lock
do
  exec 9>"$heavy_lock_path" || exit 75
  if flock -n 9; then
    heavy_slot_acquired=1
    break
  fi
  exec 9>&-
done
[ "$heavy_slot_acquired" -eq 1 ] || exit 75
# Expected compilation peak <=2 GiB plus the mandatory 4 GiB reserve.
awk '$1 == "MemAvailable:" { available = $2 } END { exit (available < 6291456) }' /proc/meminfo || exit 75
awk '$1 == "full" { split($2, value, "="); ok = (value[2] < 1) } END { exit !ok }' /proc/pressure/memory || exit 75
export CARGO_BUILD_JOBS=1

sui move build -p sui/market_maker --warnings-are-errors --lint
sui move test -p sui/market_maker --threads 1 --warnings-are-errors --lint
python3 scripts/check_move_style.py
python3 sui/market_maker/scripts/check_boundaries.py
python3 scripts/gen_llms.py --check
