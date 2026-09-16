#!/usr/bin/env bash
set -euo pipefail

SECONDS_TO_CAPTURE=60
UDID="${SIMULATOR_UDID:-booted}"
OUTPUT_FILE=""

usage() {
  cat <<'USAGE'
Usage: collect-perf-logs.sh [--seconds N] [--udid UDID] [--output FILE]

Collect BlueStoneIM simulator performance logs without changing app behavior.
The script listens for existing [JHT Perf] / [JHT Sync] print logs and prints a
short summary for startup, cache restore, reconnect recovery, and sync failures.

Examples:
  scripts/collect-perf-logs.sh --seconds 90
  scripts/collect-perf-logs.sh --udid C4F590F7-E193-4EDB-8FF2-4AC5F250B116 --output /tmp/im2-perf.log
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --seconds)
      SECONDS_TO_CAPTURE="${2:-}"
      shift 2
      ;;
    --udid)
      UDID="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_TO_CAPTURE" in
  ''|*[!0-9]*)
    printf -- '--seconds must be a positive integer\n' >&2
    exit 2
    ;;
esac

if [ "$SECONDS_TO_CAPTURE" -le 0 ]; then
  printf -- '--seconds must be greater than 0\n' >&2
  exit 2
fi

if [ -z "$OUTPUT_FILE" ]; then
  OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/im2-ios-perf.XXXXXX.log")"
fi

PREDICATE='process == "BlueStoneIM" AND (eventMessage CONTAINS "[JHT Perf]" OR eventMessage CONTAINS "[JHT Sync]" OR eventMessage CONTAINS "实时连接中断" OR eventMessage CONTAINS "聊天记录同步失败")'

printf 'Collecting BlueStoneIM performance logs for %ss from simulator %s...\n' "$SECONDS_TO_CAPTURE" "$UDID"
printf 'Raw log: %s\n' "$OUTPUT_FILE"

set +e
xcrun simctl spawn "$UDID" log stream --style compact --predicate "$PREDICATE" >"$OUTPUT_FILE" 2>&1 &
LOG_PID=$!
set -e

cleanup() {
  if kill -0 "$LOG_PID" >/dev/null 2>&1; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

sleep "$SECONDS_TO_CAPTURE"
cleanup
trap - EXIT

printf '\nSummary:\n'
awk '
  /cached_snapshot_applied/ { cached++ }
  /restore_start/ { restore++ }
  /conversation_list_ready_ms=/ {
    listReadyCount++
    if (match($0, /conversation_list_ready_ms=[0-9]+/)) {
      value = substr($0, RSTART + 27, RLENGTH - 27) + 0
      listReadyTotal += value
      if (listReadyMax < value) listReadyMax = value
      if (listReadyMin == 0 || value < listReadyMin) listReadyMin = value
    }
  }
  /history_prefetch_complete_ms=/ {
    historyCount++
    if (match($0, /history_prefetch_complete_ms=[0-9]+/)) {
      value = substr($0, RSTART + 29, RLENGTH - 29) + 0
      historyTotal += value
      if (historyMax < value) historyMax = value
      if (historyMin == 0 || value < historyMin) historyMin = value
    }
  }
  /fps_summary/ {
    fpsSamples++
    if (match($0, /fps=[0-9]+(\.[0-9]+)?/)) {
      fpsValue = substr($0, RSTART + 4, RLENGTH - 4) + 0
      fpsTotal += fpsValue
      if (fpsMax < fpsValue) fpsMax = fpsValue
      if (fpsMin == 0 || fpsValue < fpsMin) fpsMin = fpsValue
    }
    if (match($0, /hitch_count=[0-9]+/)) {
      fpsHitches += substr($0, RSTART + 12, RLENGTH - 12) + 0
    }
    if (match($0, /dropped_frames=[0-9]+/)) {
      fpsDropped += substr($0, RSTART + 15, RLENGTH - 15) + 0
    }
    if (match($0, /max_frame_ms=[0-9]+/)) {
      frameSummaryMS = substr($0, RSTART + 13, RLENGTH - 13) + 0
      if (frameSummaryMS > fpsMaxFrame) fpsMaxFrame = frameSummaryMS
    }
  }
  /frame_hitch/ {
    severeFrameHitches++
    if (match($0, /frame_ms=[0-9]+/)) {
      frameMS = substr($0, RSTART + 9, RLENGTH - 9) + 0
      if (frameMS > severeFrameMaxMS) severeFrameMaxMS = frameMS
    }
  }
  /realtime_recovery_refresh/ { recovery++ }
  /endpoint_failed/ { endpointFailed++ }
  /snapshot_failed/ { snapshotFailed++ }
  /聊天记录同步失败|history_sync_failed/ { historyFailed++ }
  /实时连接中断/ { reconnectToast++ }
  END {
    printf "  cached snapshot applied: %d\n", cached + 0
    printf "  restore starts: %d\n", restore + 0
    if (listReadyCount > 0) {
      printf "  conversation list ready: count=%d min=%dms avg=%.0fms max=%dms\n", listReadyCount, listReadyMin, listReadyTotal / listReadyCount, listReadyMax
    } else {
      printf "  conversation list ready: no samples\n"
    }
    if (historyCount > 0) {
      printf "  history prefetch complete: count=%d min=%dms avg=%.0fms max=%dms\n", historyCount, historyMin, historyTotal / historyCount, historyMax
    } else {
      printf "  history prefetch complete: no samples\n"
    }
    if (fpsSamples > 0) {
      printf "  fps summary: count=%d min=%.1f avg=%.1f max=%.1f hitches=%d dropped=%d max_frame=%dms\n", fpsSamples, fpsMin, fpsTotal / fpsSamples, fpsMax, fpsHitches, fpsDropped, fpsMaxFrame
    } else {
      printf "  fps summary: no samples\n"
    }
    printf "  severe frame hitches: count=%d max=%dms\n", severeFrameHitches + 0, severeFrameMaxMS + 0
    printf "  realtime recovery refreshes: %d\n", recovery + 0
    printf "  reconnect toast samples: %d\n", reconnectToast + 0
    printf "  endpoint failures: %d\n", endpointFailed + 0
    printf "  snapshot failures: %d\n", snapshotFailed + 0
    printf "  history sync failures: %d\n", historyFailed + 0
  }
' "$OUTPUT_FILE"

printf '\nRecent matching lines:\n'
tail -n 40 "$OUTPUT_FILE" || true
