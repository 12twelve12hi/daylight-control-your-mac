#!/usr/bin/env bash
# Called by mac-test.sh when the tests fail (Review 4 CI-1, request 4): name the crash in the job log, since the
# artifact host is out of reach for some readers. Prints the crash lines xcodebuild wrote into the test log, then a
# summary of each Daylight or xctest crash report (.ips) newer than SINCE (a file touched before the tests started):
# exception, termination reason and the crashed thread's top frames. Copies the reports into build/xcodebuild-logs/.
# Usage: scripts/crash-summary.sh TEST_LOG SINCE [REPORT_DIR [COPY_TO]]
#   REPORT_DIR defaults to ~/Library/Logs/DiagnosticReports, COPY_TO to build/xcodebuild-logs.
set -uo pipefail
log="${1:?usage: crash-summary.sh TEST_LOG SINCE [REPORT_DIR]}"
since="${2:?usage: crash-summary.sh TEST_LOG SINCE [REPORT_DIR]}"
dir="${3:-$HOME/Library/Logs/DiagnosticReports}"
copy_to="${4:-build/xcodebuild-logs}"
echo "crash-summary: crash lines in $(basename "$log"):"
grep -E 'Fatal error|Thread [0-9]+ Crashed|Exception Type|Termination Reason|EXC_[A-Z_]+|Assertion failed|BUG IN CLIENT' "$log" 2>/dev/null | head -40 || true
command -v python3 >/dev/null 2>&1 || { echo "crash-summary: python3 not found; reports not summarised"; exit 0; }
found=0
while IFS= read -r report; do
  [[ -n "$report" ]] || continue
  [[ "$report" -nt "$since" || ! -e "$since" ]] || continue
  found=$((found + 1))
  echo "crash-summary: $report"
  python3 - "$report" <<'PY' || echo "crash-summary: could not parse $report"
import json, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
header, _, body = text.partition("\n")
try:
    data = json.loads(body)
except ValueError:
    print(text[:4000]); sys.exit(0)
exc = data.get("exception", {})
print("  exception: %s %s %s" % (exc.get("type", "?"), exc.get("signal", ""), exc.get("subtype", "")))
term = data.get("termination", {})
if term:
    print("  termination: %s %s" % (term.get("namespace", ""), term.get("indicator", "")))
asi = data.get("asi")
if asi:
    for owner, lines in asi.items():
        for line in lines[:4]:
            print("  asi %s: %s" % (owner, line))
images = [i.get("name", "?") for i in data.get("usedImages", [])]
threads = data.get("threads", [])
index = data.get("faultingThread")
crashed = threads[index] if isinstance(index, int) and 0 <= index < len(threads) else next((t for t in threads if t.get("triggered")), None)
if crashed is None:
    print("  no crashed thread in the report"); sys.exit(0)
print("  crashed thread %s queue %s:" % (index, crashed.get("queue", "-")))
for n, f in enumerate(crashed.get("frames", [])[:25]):
    i = f.get("imageIndex")
    image = images[i] if isinstance(i, int) and 0 <= i < len(images) else "?"
    print("    %2d %-24s %s +%s" % (n, image, f.get("symbol", "0x%x" % f.get("imageOffset", 0)), f.get("symbolLocation", 0)))
PY
  mkdir -p "$copy_to" && cp "$report" "$copy_to"/ 2>/dev/null || true
done < <(ls -t "$dir"/Daylight*.ips "$dir"/xctest*.ips 2>/dev/null | head -3)
echo "crash-summary: $found crash report(s) from this run"
exit 0
