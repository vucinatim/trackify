#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
output_dir=${1:-"$repo_root/.build/ui-validation"}
if (( $# > 0 )); then
  shift
fi
requested_cases=("$@")
data_root=$(mktemp -d /tmp/trackify-ui-validation.XXXXXX)
empty_root=$(mktemp -d /tmp/trackify-ui-empty.XXXXXX)
app_pid=""

cleanup() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -rf "$data_root"
  rm -rf "$empty_root"
}
trap cleanup EXIT INT TERM

cd "$repo_root"
mkdir -p "$output_dir"
swift build
showcase_ready=0

ensure_showcase() {
  if (( showcase_ready == 1 )); then
    return
  fi
  .build/debug/trackify simulate \
    --scenario showcase \
    --days 42 \
    --start 2026-06-25T22:00:00Z \
    --output-data-root "$data_root"
  showcase_ready=1
}

window_id() {
  local target_pid=$1
  local capture_sheet=${2:-0}
  TRACKIFY_CAPTURE_PID="$target_pid" TRACKIFY_CAPTURE_SHEET="$capture_sheet" swift -e '
    import CoreGraphics
    import Foundation
    let targetPID = Int(ProcessInfo.processInfo.environment["TRACKIFY_CAPTURE_PID"]!)!
    let captureSheet = ProcessInfo.processInfo.environment["TRACKIFY_CAPTURE_SHEET"] == "1"
    // Menu-bar accessory apps may be rendered by WindowServer before their
    // validation window is assigned to the active Space. Window-ID capture is
    // still deterministic, so include all process windows here.
    let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)! as! [[String: Any]]
    for window in windows {
      let owner = window[kCGWindowOwnerName as String] as? String
      let title = window[kCGWindowName as String] as? String ?? ""
      let ownerPID = window[kCGWindowOwnerPID as String] as? Int
      let layer = window[kCGWindowLayer as String] as? Int
      let bounds = window[kCGWindowBounds as String] as? [String: Any]
      let width = bounds?["Width"] as? Double ?? 0
      let height = bounds?["Height"] as? Double ?? 0
      let isSheet = title.isEmpty && layer == 0 && width >= 600 && width <= 1_000 && height >= 500 && height <= 900
      if owner == "TrackifyMac", ownerPID == targetPID,
        (captureSheet ? isSheet : title == "Trackify")
      {
        print(window[kCGWindowNumber as String]!)
        break
      }
    }
  ' | tr -d '[:space:]'
}

capture() {
  local screen=$1
  local source_root=$2
  local name=$3
  local window_width=$4
  local window_height=$5
  local screen_range=${6:-}
  local screen_date=${7:-}
  local settings_tab=${8:-}
  local color_scheme=${9:-}
  local reports_mode=${10:-}
  local reports_sheet=${11:-}
  local overview_metric=${12:-}
  local chart_tooltip=${13:-}
  if (( ${#requested_cases[@]} > 0 )) && (( ${requested_cases[(Ie)$name]} == 0 )); then
    return
  fi
  if [[ "$source_root" == "$data_root" ]]; then
    ensure_showcase
  fi
  env \
    TRACKIFY_DATA_ROOT="$source_root" \
    TRACKIFY_UI_VALIDATION=1 \
    TRACKIFY_UI_NOW=2026-08-06T10:00:00Z \
    TRACKIFY_UI_SCREEN="$screen" \
    TRACKIFY_UI_WIDTH="$window_width" \
    TRACKIFY_UI_HEIGHT="$window_height" \
    TRACKIFY_UI_RANGE="$screen_range" \
    TRACKIFY_UI_DATE="$screen_date" \
    TRACKIFY_UI_SETTINGS_TAB="$settings_tab" \
    TRACKIFY_UI_SCHEME="$color_scheme" \
    TRACKIFY_UI_REPORTS_MODE="$reports_mode" \
    TRACKIFY_UI_REPORTS_SHEET="$reports_sheet" \
    TRACKIFY_UI_METRIC="$overview_metric" \
    TRACKIFY_UI_CHART_TOOLTIP="$chart_tooltip" \
    .build/debug/TrackifyMac >"/tmp/trackify-ui-$name.log" 2>&1 &
  app_pid=$!

  local id=""
  local attempt
  local capture_sheet=0
  [[ -n "$reports_sheet" ]] && capture_sheet=1
  for attempt in {1..60}; do
    id=$(window_id "$app_pid" "$capture_sheet")
    [[ -n "$id" ]] && break
    sleep 0.25
  done
  if [[ -z "$id" ]]; then
    print -u2 "Trackify window did not appear for '$screen'."
    return 1
  fi
  local ready=0
  for attempt in {1..120}; do
    if grep -q '^TRACKIFY_UI_READY$' "/tmp/trackify-ui-$name.log"; then
      ready=1
      break
    fi
    sleep 0.1
  done
  if (( ready == 0 )); then
    print -u2 "Trackify model did not finish loading for '$screen'."
    return 1
  fi
  sleep 0.15

  local captured=0
  for attempt in {1..20}; do
    if screencapture -x -l "$id" "$output_dir/$name.png" 2>/dev/null; then
      captured=1
      break
    fi
    sleep 0.25
  done
  if (( captured == 0 )); then
    print -u2 "Trackify window could not be captured for '$screen'."
    return 1
  fi
  local width=$(sips -g pixelWidth "$output_dir/$name.png" | awk '/pixelWidth/ { print $2 }')
  local height=$(sips -g pixelHeight "$output_dir/$name.png" | awk '/pixelHeight/ { print $2 }')
  if (( width < 1000 || height < 700 )); then
    print -u2 "Unexpected screenshot size for '$screen': ${width}x${height}."
    return 1
  fi

  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  app_pid=""
  print "$name: $output_dir/$name.png (${width}x${height})"
}

capture overview "$data_root" overview 1180 800
capture overview "$data_root" overview-day 1180 800 day
capture overview "$data_root" overview-day-historical 1180 800 day 2026-08-05T10:00:00Z
capture overview "$data_root" overview-week-turns 1180 800 "7 days" "" "" dark "" "" llm-turns
capture overview "$data_root" overview-week-commits 1180 800 "7 days" "" "" dark "" "" commits
capture overview "$data_root" overview-month-lines 1180 800 "30 days" "" "" dark "" "" committed-lines
capture overview "$data_root" overview-tooltip-edge 1180 800 "7 days" "" "" dark "" "" committed-lines edge
capture activity "$data_root" activity 1180 800
capture projects "$data_root" projects 1180 800
capture reports "$data_root" reports-history 1380 900
capture reports "$empty_root" reports-history-empty 1380 900
capture reports "$empty_root" reports-history-empty-tall 1600 1100
capture reports "$data_root" reports-templates 1380 900 "" "" "" dark templates
capture reports "$data_root" reports-scheduled 1380 900 "" "" "" dark scheduled
capture reports "$data_root" reports-composer 1380 900 "" "" "" dark history new-report
capture reports "$data_root" reports-template-editor 1380 900 "" "" "" dark templates new-template
capture activity "$data_root" activity-tall 1600 1100
capture overview "$empty_root" overview-empty 1180 800
capture activity "$empty_root" activity-empty 1180 800
capture settings "$data_root" settings-sources 1180 800 "" "" sources light
capture settings "$data_root" settings-summaries 1180 800 "" "" summaries dark
capture settings "$data_root" settings-usage 1180 800 "" "" usage light
