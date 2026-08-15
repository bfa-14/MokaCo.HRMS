#!/bin/bash
#
# WHICH MUTATING ACTIONS DO NOT WAKE A SUBSCRIBED PAGE?
#
# The live signal is easy to forget: a controller action is correct, its tests pass, the row is
# written — and the only symptom is that somebody else's screen goes on showing yesterday's answer
# until they reload. That failure is invisible from inside the action, which is why it kept being
# found one request type at a time (shift swaps, then separations, ...).
#
# This is the sweep that ends that. It splits every controller into per-action chunks at the [Http…]
# attribute, and reports each POST/PUT/DELETE/PATCH with whether its chunk signals — counting both a
# direct _live.NotifyAsync(...) and any private Notify*Async() helper.
#
#   bash docs/live_notify_audit.sh              # every mutating action
#   bash docs/live_notify_audit.sh | grep '|no|' # just the gaps
#
# A "no" is not automatically a bug. Seven actions are deliberately silent and say so in a comment
# at the top of their controller or action: AuthController (login/refresh/logout write only
# refresh-token rows), MeController (your own password; a signature image is frozen onto each
# decision at signing time), and AttendanceIngestionController.Preview (writes nothing). Anything
# else appearing here is a gap — fix it, or record why not, so the next run stays quiet.
#
# Output: file|VERB|Action|YES/no|topics

cd "$(dirname "$0")/../MokaCo.HRMS.API/Controllers" || exit 1

for f in *.cs; do
  awk -v FILE="$f" '
    /^[[:space:]]*\[Http(Get|Post|Put|Delete|Patch)/ {
      if (verb != "") flush()
      verb = "GET"
      if ($0 ~ /HttpPost/)   verb = "POST"
      if ($0 ~ /HttpPut/)    verb = "PUT"
      if ($0 ~ /HttpDelete/) verb = "DELETE"
      if ($0 ~ /HttpPatch/)  verb = "PATCH"
      name = ""; notify = "no"; topics = ""
      next
    }
    verb != "" {
      if (name == "" && $0 ~ /public .*(Task|IActionResult|void)/) {
        line = $0
        if (match(line, /[A-Za-z0-9_]+\(/)) name = substr(line, RSTART, RLENGTH - 1)
      }
      if ($0 ~ /_live\.NotifyAsync\(/) {
        notify = "YES"
        t = $0
        sub(/.*NotifyAsync\(/, "", t); sub(/\).*/, "", t)
        gsub(/"/, "", t); gsub(/[[:space:]]/, "", t)
        if (t != "") topics = t
      }
      if ($0 ~ /await Notify[A-Za-z]*Async\(\)/) {
        notify = "YES"
        if (topics == "") { h = $0; sub(/.*await /, "", h); sub(/\(\).*/, "", h); topics = h }
      }
    }
    function flush() {
      if (verb != "GET" && name != "")
        printf "%s|%s|%s|%s|%s\n", FILE, verb, name, notify, topics
    }
    END { if (verb != "") flush() }
  ' "$f"
done
