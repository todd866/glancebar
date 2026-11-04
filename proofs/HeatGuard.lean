/-!
# Battery heat guard — executable spec

Temperature is `Int` tenths of a degree Celsius (38.0 °C → `380`) to match the C
`double tempC` thresholds without floats: `kBatteryCoolC = 35`, `kBatteryWarmC = 38`.
Transcription of `HeatGuardStep` in `Sources/pure.m`.
-/

namespace HeatGuard

inductive State where
  | idle
  | engaged
  | stoodDown
  deriving Repr, DecidableEq

inductive Action where
  | nothing
  | enable
  | disable
  deriving Repr, DecidableEq

/-- Cool: read and at or below 35 °C (`kBatteryCoolC`). Unread (`≤ 0`) is not cool. -/
def cool (tempTenths : Int) : Bool :=
  tempTenths > 0 && tempTenths ≤ 350

/-- Warm: at or above 38 °C (`kBatteryWarmC`). -/
def warm (tempTenths : Int) : Bool :=
  tempTenths ≥ 380

def step (enabled : Bool) (tempTenths : Int) (lowPowerOn : Bool) (s : State) : Action × State :=
  match s with
  | .engaged =>
    if !lowPowerOn then (Action.nothing, State.stoodDown)
    else if !enabled || cool tempTenths then (Action.disable, State.idle)
    else (Action.nothing, s)
  | .stoodDown =>
    if !enabled || cool tempTenths then (Action.nothing, State.idle)
    else (Action.nothing, s)
  | .idle =>
    if enabled && !lowPowerOn && warm tempTenths then (Action.enable, State.engaged)
    else (Action.nothing, s)

namespace step

private theorem idle_action (enabled lowPowerOn : Bool) (tempTenths : Int) :
    (step enabled tempTenths lowPowerOn State.idle).1 =
      if enabled && !lowPowerOn && warm tempTenths then Action.enable else Action.nothing := by
  simp only [step]
  by_cases he : enabled <;> by_cases hlp : lowPowerOn <;> by_cases hw : warm tempTenths <;> simp [he, hlp, hw]

private theorem engaged_action (enabled lowPowerOn : Bool) (tempTenths : Int) :
    (step enabled tempTenths lowPowerOn State.engaged).1 =
      if !lowPowerOn then Action.nothing
      else if !enabled || cool tempTenths then Action.disable else Action.nothing := by
  simp only [step]
  by_cases hlp : lowPowerOn <;> by_cases he : enabled <;> by_cases hc : cool tempTenths <;> simp [hlp, he, hc]

private theorem stoodDown_action (enabled : Bool) (tempTenths : Int) (lowPowerOn : Bool) :
    (step enabled tempTenths lowPowerOn State.stoodDown).1 = Action.nothing := by
  simp only [step]
  by_cases he : enabled <;> by_cases hc : cool tempTenths <;> simp [he, hc]

private theorem warm_of_and (enabled lowPowerOn : Bool) (tempTenths : Int)
    (h : enabled && !lowPowerOn && warm tempTenths = true) : tempTenths ≥ 380 := by
  by_cases he : enabled
  · by_cases hlp : lowPowerOn
    · simp [he, hlp, warm] at h
    · by_cases hw : 380 ≤ tempTenths
      · exact hw
      · simp [he, hlp, hw, warm] at h
  · simp [he, warm] at h

/-- Weaker substitute for the false global `unread_never_acts`; see comment above. -/
theorem unread_never_enables {enabled lowPowerOn : Bool} {tempTenths : Int} {s : State}
    (h : tempTenths ≤ 0) : (step enabled tempTenths lowPowerOn s).1 ≠ Action.enable := by
  intro he
  rcases s with _ | _ | _
  · rw [idle_action] at he
    by_cases H : enabled && !lowPowerOn && warm tempTenths
    · have hw := warm_of_and enabled lowPowerOn tempTenths (by simp [H])
      omega
    · simp [H] at he
  · rw [engaged_action] at he
    by_cases H : !lowPowerOn <;> by_cases H' : !enabled || cool tempTenths <;> simp [H, H'] at he
  · rw [stoodDown_action] at he
    cases he

/-!
`unread_never_acts` (action always `nothing` when `tempTenths ≤ 0`) is **false** for the C
model: e.g. `step false 0 true State.engaged = (Action.disable, State.idle)` — guard disabled
while still engaged with Low Power on releases with `Disable` even though temperature is unread.
The unit test only checks unread from `Idle` (`HeatGuardStep(YES, 0, NO, &idle)`).
-/

theorem unread_idle_never_acts (enabled lowPowerOn : Bool) (tempTenths : Int)
    (h : tempTenths ≤ 0) :
    (step enabled tempTenths lowPowerOn State.idle) = (Action.nothing, State.idle) := by
  simp only [step]
  by_cases H : enabled && !lowPowerOn && warm tempTenths
  · exfalso
    have hw := warm_of_and enabled lowPowerOn tempTenths (by simp [H])
    omega
  · simp [H]

theorem disabled_never_enables (enabled : Bool) {tempTenths : Int} {lowPowerOn : Bool} {s : State}
    (h : enabled = false) : (step enabled tempTenths lowPowerOn s).1 ≠ Action.enable := by
  subst h
  intro he
  rcases s with _ | _ | _
  · rw [idle_action] at he
    by_cases H : false && !lowPowerOn && warm tempTenths <;> simp at he
  · rw [engaged_action] at he
    by_cases H : !lowPowerOn
    · simp [H] at he
    · simp [H] at he
  · rw [stoodDown_action] at he
    cases he

theorem disable_only_from_engaged {enabled : Bool} {tempTenths : Int} {lowPowerOn : Bool}
    {s : State} (h : (step enabled tempTenths lowPowerOn s).1 = Action.disable) :
    s = State.engaged := by
  rcases s with _ | _ | _
  · exfalso
    rw [idle_action] at h
    by_cases H : enabled && !lowPowerOn && warm tempTenths <;> simp [H] at h
  · rfl
  · exfalso
    rw [stoodDown_action] at h
    cases h

theorem enable_only_when_warm_and_off {enabled : Bool} {tempTenths : Int} {lowPowerOn : Bool}
    {s : State} (h : (step enabled tempTenths lowPowerOn s).1 = Action.enable) :
    tempTenths ≥ 380 ∧ lowPowerOn = false ∧ s = State.idle := by
  rcases s with _ | _ | _
  · rw [idle_action] at h
    by_cases H : enabled && !lowPowerOn && warm tempTenths
    · have hw := warm_of_and enabled lowPowerOn tempTenths (by simp [H])
      have hlp : lowPowerOn = false := by
        cases lowPowerOn
        · rfl
        · exfalso
          simp at H
      exact ⟨hw, hlp, rfl⟩
    · simp [H] at h
  · exfalso
    rw [engaged_action] at h
    by_cases H : !lowPowerOn <;> by_cases H' : !enabled || cool tempTenths <;> simp [H, H'] at h
  · exfalso
    rw [stoodDown_action] at h
    cases h

theorem user_override_stands_down (enabled : Bool) (tempTenths : Int) {lowPowerOn : Bool}
    (hlp : lowPowerOn = false) :
    step enabled tempTenths lowPowerOn State.engaged = (Action.nothing, State.stoodDown) := by
  subst hlp
  simp [step]

end step

end HeatGuard

open HeatGuard

-- Mirrors `Tests/test_pure.m` HeatGuardStep checks (temperatures in tenths °C).

#eval step false 450 false State.idle -- guard: off does nothing → (nothing, idle)
#eval step true 370 false State.idle -- guard: below warm does nothing
#eval step true 0 false State.idle -- guard: unread temperature never acts (from idle)
#eval step false 0 true State.engaged -- counterexample: unread but still Disable when engaged + guard off
#eval step true 380 false State.idle -- guard: warm engages
#eval step true 360 true State.engaged -- guard: holds between 35 and 38
#eval step true 350 true State.engaged -- guard: cool releases
#eval step true 400 true State.idle -- guard: user's Low Power left alone
#eval step true 330 true State.idle -- guard: never turns off user's Low Power
#eval step true 400 false State.engaged -- guard: user switching Low Power off stands down
#eval step true 410 false State.stoodDown -- guard: stays stood down while warm
#eval step true 350 false State.stoodDown -- guard: re-arms once cool
#eval step false 400 true State.engaged -- guard: unticking undoes its own Low Power
