#!/usr/bin/env bash
# review-pr: print daily-review's review guidance, so /review-pr reviews exactly the way
# /daily-review does. Prints daily-review's SKILL.md from "## What this is for" to the end,
# without the weekly architecture section, with ${CLAUDE_SKILL_DIR} pointing at daily-review.

DR=$(cd "$(dirname "$0")/../../daily-review" 2>/dev/null && pwd)
if [ -z "$DR" ] || [ ! -f "$DR/SKILL.md" ]; then
  echo "(The daily-review skill was not found next to review-pr. Reinstall the daily-review plugin.)"
  exit 0
fi
ESC=$(printf '%s' "$DR" | sed -e 's/[\\&|]/\\&/g')
awk '/^## What this is for/ { on = 1 } /^## / { skip = ($0 ~ /^## Weekly architecture review/) } on && !skip' "$DR/SKILL.md" \
  | sed -e "s|\${CLAUDE_SKILL_DIR}|$ESC|g"
exit 0
