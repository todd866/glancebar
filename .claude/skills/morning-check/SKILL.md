---
name: morning-check
description: Run the menu-bar morning check and repair each Glancebar or Energybar FAIL or WARN it reports. Never push without a green suite.
---

# Morning check

Run `tools/ops/menubar-morning-check.sh` from the glancebar checkout. Read `~/Library/Logs/menubar-morning-check/latest.txt`.

Fix each FAIL and WARN in the repo that owns it. Glancebar: tests pass, then build, install to `/Applications`, relaunch, commit to main. Energybar: the same sequence in `~/Projects/energybar`. Do not push until the suite that covers the change is green.

End with one line per area: status and the short fact, after the repair.
