#!/usr/bin/env bash
# measure-footprint.sh — Idle performance measurement for MeetingAlert
#
# Methodology from research/03-performance-memory.md:
#   Budget metric  : phys_footprint via `footprint` (NO sudo — works for your own process)
#   Informational  : RSS via `ps` (overstates memory: includes shared COW pages)
#   CPU            : %cpu via `ps`
#   Budget         : phys_footprint < 30 MB at idle (menu closed, no overlay)
#
# Exit codes: 0 = PASS, 1 = FAIL (phys_footprint over budget), 2 = UNMEASURED (tool failure).
# RSS is NEVER judged against the budget (F-002) — it is printed for information only.
#
# Usage:
#   ./scripts/measure-footprint.sh               # full 5-minute idle run
#   DURATION=15 ./scripts/measure-footprint.sh   # quick smoke test
#
# Env-var overrides:
#   DURATION        seconds to idle (default 300)
#   SAMPLE_INTERVAL seconds between samples (default 10)
#   SKIP_BUILD      set to 1 to reuse an existing bundle (skips swift build + bundle step)

set -euo pipefail

DURATION="${DURATION:-300}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-10}"
SKIP_BUILD="${SKIP_BUILD:-0}"
MEM_BUDGET_MB=30

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RELEASE_BIN="$REPO_ROOT/.build/release/MeetingAlert"
APP_BUNDLE="$REPO_ROOT/.build/MeetingAlert.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"

# ── helpers ────────────────────────────────────────────────────────────────────
die() { echo "ERROR: $*" >&2; exit 1; }

hr() { printf '%0.s─' {1..57}; echo; }

# ── 1. Build release + produce .app bundle ────────────────────────────────────
if [[ "$SKIP_BUILD" == "1" && -d "$APP_BUNDLE" ]]; then
    echo "==> Skipping build (SKIP_BUILD=1), reusing $APP_BUNDLE"
else
    echo "==> Building MeetingAlert (release) …"
    cd "$REPO_ROOT"
    swift build -c release 2>&1
    [[ -x "$RELEASE_BIN" ]] || die "Release binary not found at $RELEASE_BIN."

    # Assemble minimal .app bundle (as documented in README-scaffold.md)
    echo "==> Bundling MeetingAlert.app …"
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_MACOS"
    cp "$RELEASE_BIN" "$APP_MACOS/MeetingAlert"
    cp "$REPO_ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

    # Ad-hoc sign so macOS accepts it (no Xcode project / provisioning needed).
    # --identifier pins a stable signing identifier (F-059); credentials persist in a 0600 file
    # keyed by bundle id, not the Keychain, so ad-hoc rebuilds no longer drop the login.
    codesign --force --options runtime \
        --identifier com.disco-tec.MeetingAlert \
        --entitlements "$REPO_ROOT/MeetingAlert.entitlements" \
        --sign - "$APP_BUNDLE" 2>&1 \
        || echo "WARNING: codesign failed — continuing without signature."

    echo "==> Bundle ready: $APP_BUNDLE"
fi

# ── 2. Launch via `open` so macOS assigns a proper bundle context ─────────────
echo "==> Launching app (idle ${DURATION}s, sampling every ${SAMPLE_INTERVAL}s) …"

# Kill any pre-existing instance to avoid PID confusion
pkill -x MeetingAlert 2>/dev/null || true
sleep 1

open "$APP_BUNDLE"

# Allow the app up to 5 s to appear in the process table
INIT_WAIT=5
for i in $(seq 1 "$INIT_WAIT"); do
    APP_PID=$(pgrep -x MeetingAlert 2>/dev/null || true)
    [[ -n "$APP_PID" ]] && break
    sleep 1
done
[[ -n "${APP_PID:-}" ]] || die "MeetingAlert did not appear in process list after ${INIT_WAIT}s."

echo "==> PID $APP_PID — sampling …"

# Ensure we kill the app on exit
cleanup() {
    pkill -x MeetingAlert 2>/dev/null || true
}
trap cleanup EXIT

# ── 3. Sample loop ─────────────────────────────────────────────────────────────
declare -a TS_LIST=()
declare -a RSS_LIST=()   # kilobytes (from ps)
declare -a CPU_LIST=()   # percent (from ps; string with possible decimal)

ELAPSED=0
while [[ $ELAPSED -lt "$DURATION" ]]; do
    # Re-resolve PID each iteration in case app restarted
    LIVE_PID=$(pgrep -x MeetingAlert 2>/dev/null || true)
    if [[ -z "$LIVE_PID" ]]; then
        echo "WARNING: MeetingAlert exited at ${ELAPSED}s — stopping early." >&2
        break
    fi

    rss_kb=$(ps -p "$LIVE_PID" -o rss=  2>/dev/null | awk '{print $1}' || echo 0)
    cpu_pct=$(ps -p "$LIVE_PID" -o %cpu= 2>/dev/null | awk '{print $1}' || echo 0.0)

    TS_LIST+=("$ELAPSED")
    RSS_LIST+=("${rss_kb:-0}")
    CPU_LIST+=("${cpu_pct:-0.0}")

    sleep "$SAMPLE_INTERVAL"
    ELAPSED=$((ELAPSED + SAMPLE_INTERVAL))
done

N="${#TS_LIST[@]}"
[[ "$N" -gt 0 ]] || die "No samples collected."

# ── 4. Measure phys_footprint via `footprint` (NO sudo — F-002) ───────────────
# `footprint` reads phys_footprint for the current user's OWN process without sudo
# (verified in F-001). We do NOT silence its stderr, so a genuine tool failure is visible
# instead of being misread as "unavailable".
PHYS_MB="N/A"
LIVE_PID=$(pgrep -x MeetingAlert 2>/dev/null || true)
if command -v footprint &>/dev/null && [[ -n "$LIVE_PID" ]]; then
    fp_raw=$(footprint -p MeetingAlert || true)
    if [[ -n "$fp_raw" ]]; then
        # The `footprint` tool prints the budget metric as `phys_footprint: <N> <unit>`
        # in its "Auxiliary data" block (NOT "Physical footprint:" — that is vmmap's label).
        fp_line=$(echo "$fp_raw" | grep -iE "phys_footprint:" | head -1 || true)
        if [[ -n "$fp_line" ]]; then
            # `footprint` prints "phys_footprint: 21 MB" — value and unit are SEPARATE fields
            # (not "21M" joined like vmmap). Take the field after the colon, then split num/unit.
            fp_after=$(echo "$fp_line" | awk -F':' '{print $2}')
            fp_num=$(echo "$fp_after"  | awk '{print $1}' | sed 's/[^0-9.]//g')
            fp_unit=$(echo "$fp_after" | awk '{print $2}' | sed 's/[^A-Za-z]//g' | tr '[:lower:]' '[:upper:]')
            [[ -z "$fp_unit" ]] && fp_unit="M"   # footprint header sometimes omits unit → assume MB
            case "$fp_unit" in
                K|KB)  PHYS_MB=$(awk -v n="$fp_num" 'BEGIN { printf "%.2f", n/1024 }') ;;
                M|MB)  PHYS_MB=$(awk -v n="$fp_num" 'BEGIN { printf "%.2f", n }') ;;
                G|GB)  PHYS_MB=$(awk -v n="$fp_num" 'BEGIN { printf "%.2f", n*1024 }') ;;
                *)  PHYS_MB=$(awk -v n="$fp_num" 'BEGIN { printf "%.2f", n/1048576 }') ;;
            esac
        fi
    fi
fi

# Terminate app now that measurements are done
cleanup
trap - EXIT

# ── 5. Compute summary stats via awk ──────────────────────────────────────────
RSS_SPACE="${RSS_LIST[*]}"
CPU_SPACE="${CPU_LIST[*]}"

AVG_RSS_MB=$(awk -v n="$N" -v vals="$RSS_SPACE" 'BEGIN {
    split(vals,a," "); s=0; for(i=1;i<=n;i++) s+=a[i]+0; printf "%.2f", s/n/1024 }')

PEAK_RSS_MB=$(awk -v vals="$RSS_SPACE" 'BEGIN {
    split(vals,a," "); p=0; for(i in a) if(a[i]+0>p) p=a[i]+0; printf "%.2f", p/1024 }')

AVG_CPU=$(awk -v n="$N" -v vals="$CPU_SPACE" 'BEGIN {
    split(vals,a," "); s=0; for(i=1;i<=n;i++) s+=a[i]+0; printf "%.2f", s/n }')

PEAK_CPU=$(awk -v vals="$CPU_SPACE" 'BEGIN {
    split(vals,a," "); p=0; for(i in a) if(a[i]+0>p) p=a[i]+0; printf "%.2f", p }')

# ── 6. Print sample table ─────────────────────────────────────────────────────
echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│          MeetingAlert — Idle Footprint Report            │"
echo "├──────────┬────────────────────┬────────────────────────┤"
echo "│  Elapsed │    RSS (MB)        │       CPU %            │"
echo "├──────────┼────────────────────┼────────────────────────┤"

for i in "${!TS_LIST[@]}"; do
    t="${TS_LIST[$i]}"
    rss_mb=$(awk -v k="${RSS_LIST[$i]}" 'BEGIN { printf "%.2f", k/1024 }')
    cpu="${CPU_LIST[$i]}"
    printf "│  %6ds │  %14s MB  │  %18s%%  │\n" "$t" "$rss_mb" "$cpu"
done

echo "├──────────┴────────────────────┴────────────────────────┤"
echo "│  SUMMARY                                               │"
printf "│  Samples      : %-40s│\n" "$N"
printf "│  Avg  RSS     : %-37s MB │\n" "$AVG_RSS_MB"
printf "│  Peak RSS     : %-37s MB │\n" "$PEAK_RSS_MB"
printf "│  Avg  CPU     : %-38s%% │\n" "$AVG_CPU"
printf "│  Peak CPU     : %-38s%% │\n" "$PEAK_CPU"
printf "│  phys_footprint (footprint): %-28s MB │\n" "$PHYS_MB"
printf "│  Budget       : < %s MB phys_footprint at idle            │\n" "$MEM_BUDGET_MB"
echo "└──────────────────────────────────────────────────────────┘"
echo ""

# ── 7. PASS / FAIL ────────────────────────────────────────────────────────────
# F-002: the budget is phys_footprint (research/03), NOT RSS. RSS includes clean/shared
# COW pages from the dyld shared cache that the kernel never charges to the process, so it
# overstates memory by ~40 MB for a SwiftUI/AppKit app (see F-001/F-004). We therefore judge
# ONLY against phys_footprint. If phys_footprint could not be measured we report UNMEASURED
# (a tooling gap), never a FALSE FAIL against the wrong metric.
hr
echo "  phys_footprint (budget metric) : ${PHYS_MB} MB"
echo "  RSS peak (informational, incl. shared COW pages) : ${PEAK_RSS_MB} MB"
echo ""

if [[ "$PHYS_MB" == "N/A" ]]; then
    printf "  RESULT : UNMEASURED (phys_footprint unavailable — 'footprint' tool failed)\n"
    printf "  Budget : < %s MB phys_footprint\n" "$MEM_BUDGET_MB"
    hr
    echo ""
    exit 2   # distinct from PASS(0)/FAIL(1): the gate did not run, it is not a budget failure
fi

VERDICT=$(awk -v val="$PHYS_MB" -v budget="$MEM_BUDGET_MB" \
    'BEGIN { print (val+0 < budget+0) ? "PASS" : "FAIL" }')

if [[ "$VERDICT" == "PASS" ]]; then
    printf "  RESULT : PASS\n"
else
    printf "  RESULT : FAIL\n"
fi
printf "  Metric : phys_footprint = %s MB\n" "$PHYS_MB"
printf "  Budget : < %s MB\n" "$MEM_BUDGET_MB"
hr
echo ""

[[ "$VERDICT" == "PASS" ]]
