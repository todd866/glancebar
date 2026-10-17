# Battery forecast labels

The existing battery row shows compact remaining durations above the 20% and 0%
markers while discharging, or 80% and 100% while charging. Values round to five
minutes below an hour, then tenths of an hour. Arrival clocks remain in the tooltip.
The measured text is centred exactly on each target tick. Endpoint labels may extend
past the gauge into the overlay's side room, without moving the gauge or columns.
Long adjacent labels use slightly tighter tracking at the same 9pt font size.

With the 80% limit enabled, the 100% duration assumes the owner cancels that limit.
The tooltip states this assumption. At or above 80%, both duration labels disappear.
The markers remain. Forecasting never changes the charge setting.

## Telemetry and uncertainty

Prefer the public macOS power-source estimates, retaining a valid direction-specific
IORegistry estimate when the public source is still calculating. Full charge always
requires a system estimate, which accounts for charging taper. Never project the
present charging current linearly to 100%.

A current-based estimate needs a steady minute of real samples. It resets after a
large load change, a direction change, stale telemetry, or a long sampling gap.
When a full-charge estimate is available, its remaining charge share supplies a
provisional 80% estimate during rate warm-up or a rate reset. Because the full-time
tail includes taper, this provisional value can run long; the tooltip says so.
The measured pre80 rate replaces it once steady. Without either usable source,
values use a dash with the reason in the tooltip.

On this Mac, `AppleRawCurrentCapacity`, `AppleRawMaxCapacity`, and `DesignCapacity`
are absent at the root of AppleSmartBattery. Read the mAh values from nested
`BatteryData.RemainingCapacity`, `FullChargeCapacity`, and `DesignCapacity` instead.
Never use root `CurrentCapacity` or `MaxCapacity` as mAh: they are percentages.
The legacy raw pair remains preferred on machines that expose it.

## Live verification

Launch the installed app through Launch Services with `GLANCEBAR_BATTERY_DEBUG_DIR`
set to an existing absolute directory to capture the running controller's battery
state and production battery row. Capture lasts at most two minutes, at 14-second
minimum intervals; light/dark PNGs use one pixel per point. It opens no UI and
changes no preferences. Normal launches do not capture anything.

`Tests/test_battery_forecast.m` covers the live registry shape, startup, changing
load, crossed thresholds, held charging, taper, stale readings, clock rollover,
format boundaries, and hypothetical full charge. `tools/check-popover.m` verifies
labels and target geometry across popover, Overview, and Battery views, including
both labels hidden at an enabled 80% limit.
