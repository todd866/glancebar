# Battery-bar forecasts

One 30-point instrument row, unchanged columns and 102-point popover gauge. The charge
bar sits at y=9; 9-point medium monospaced-digit durations occupy y=18–30. Endpoint labels
stay inside the gauge column; short leaders connect displaced text to exact target
ticks (20%/0% on battery, 80%/100% on AC). The same view is used by the popover,
Overview, and Battery tab. The low-charge trend arrow moves below the bar to leave
duration space clear. No extra row or control is added.

Bar labels show compact remaining time: `45m` below an hour (nearest five minutes),
`1.5h` at/above an hour (nearest tenth), and whole hours from 10h. Whole-hour decimals
are omitted (`1h`, `2h`); a rounded 60m promotes to `1h`. Under five minutes reads
`<5m`, never `0m`. Labels are independent of date/timezone. Battery Details retains approximate
local `HHmm` arrival clocks, rounded to five minutes, with `+1d` across midnight.
Reached targets omit their labels; unavailable forecasts show an em dash. Estimates are conditional on the present load
and charging state, not promises. The 0% estimate means the system's usable battery
endpoint; macOS may sleep before literal electrochemical exhaustion.

## Inputs and honesty

- `ReadBattery` prefers public IOPS `Time to Empty` and `Time to Full Charge` values.
  The installed SDK's `IOKit/ps/IOPSKeys.h` defines minute units, -1 as calculating,
  and which charging/source states make each valid. Registry `AvgTimeToEmpty` /
  `AvgTimeToFull` are fallback fields. Direction-dependent `TimeRemaining` is not
  repurposed. Zero, sentinels, invalid types and estimates over 24 hours are unknown.
- Time to 20% scales the system's usable time to empty by displayed percent headroom.
  If empty time is unavailable, a steady minute of measured current and raw charge
  capacity can supply the fallback. Charging to 80% uses that steady current.
- Time to 100% **only** uses macOS's full estimate, retaining taper. It is suppressed
  under the known 80% limit, when charging pauses, or when the charging flag and net
  current do not agree. A pre-80 estimate later than the full estimate is withheld.
- Samples are at least 10 seconds apart, span at least 60 seconds, and retain at most
  90 seconds. Variation must be within 20%; a >30% current step starts a new window.
  Direction/limit changes, >90-second gaps, backward wall-clock jumps, invalid battery,
  and registry telemetry over 120 seconds old clear history and forecast state.
- Small arrival changes use a 30-second time constant. Revisions over 25% (at least
  five minutes) apply immediately. Missing source values clear their predictions;
  no last-good deadline survives as a fabricated future ETA.

## Verification

`./tests.sh` includes deterministic battery cases in `Tests/test_battery_forecast.m`
and the production offscreen AppKit layout harness. The latter renders discharge,
charge, taper, pause, full, startup, and low battery; checks both target anchors,
nonintersecting duration bounds, unchanged row height, all three surfaces, and the
existing popover/detail constraints. Pass a PNG path to the compiled harness to save
images; add a second argument for dark mode. `GLANCEBAR_RENDER_1X=1` renders at
one pixel per point. `GLANCEBAR_RENDER_LIVE_BATTERY=1` adds a real battery snapshot
in the fixture panel and logs its actual telemetry, without starting samplers or
opening windows. Synthetic render history is never used for that live snapshot.

Local validation uses the machine's `heavy-slot` and battery guard. Charging modes are
synthetic fixtures; no charging setting is changed and no battery drain is induced.

For builds under a Finder-managed Documents folder, set
`GLANCEBAR_BUILD_DIR=/tmp/glancebar-battery-build` to keep signing staging out of
that folder. The build removes only FinderInfo/ResourceFork decoration from its
own staged app; it does not remove quarantine or change trust/security settings.
