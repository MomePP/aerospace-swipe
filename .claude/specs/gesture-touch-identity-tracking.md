# Stable per-finger touch tracking for gesture detection

## Problem

Real 4-finger swipes frequently fail to register, even at the "High" sensitivity
preset, and produce no visible feedback when they fail (not a partial trigger,
not a snap-back — just nothing).

## Root cause

`process_touches` (`src/main.m`) builds each frame's touch array by iterating
an `NSSet<NSTouch*>`:

```objc
for (NSTouch* touch in touches) {
    ...
    buf[i++] = [TouchConverter convert_nstouch:touch];
}
```

`NSSet` enumeration order is not guaranteed to be stable across separate
enumerations — and each gesture callback receives a *new* `NSSet` from a new
`CGEvent`. The gesture state machine (`gestureCallback`, `handle_idle_state`,
`handle_armed_state`, `handle_committed_state`, all in `src/main.m`) indexes
its per-finger history (`gesture_ctx.prev_x[i]`, `gesture_ctx.base_x[i]`) by
this raw array position, implicitly assuming `touches[i]` this callback is the
same physical finger as `touches[i]` last callback. That assumption doesn't
hold.

When the enumeration order shuffles between two consecutive callbacks (which
gets more likely the more fingers are down — 4 fingers has more possible
orderings than 2 or 3), `handle_armed_state`'s per-finger consistency check

```c
float ddx = touches[i].x - ctx->prev_x[i];
if (fabsf(ddx) < stepReq || (ddx * dx) < 0) {
    mismatch_count++;
    if (mismatch_count > g_config.swipe_tolerance) {
        reset_gesture_state(ctx);
        return;
    }
}
```

ends up diffing two *different* fingers' positions against each other,
producing a garbage delta. That inflates `mismatch_count` past
`swipe_tolerance` and silently resets the gesture — with no error, log line,
or user-visible signal. This is judged the primary cause of "hard to swipe
with 4 fingers."

`NSTouch` does expose a stable per-finger `identity` — `event_tap.m` already
reads it (`TouchConverter convert_nstouch:`) to key a `touchStates`
`CFMutableDictionary` used for velocity smoothing — but that identity is
discarded rather than surfaced to `main.m`, so the gesture code has no way to
know which array slot maps to which finger.

A secondary, smaller contributor: `gestureCallback` requires an *exact* touch
count match —

```c
if (count != g_config.fingers) {
    if (ctx->state == GS_ARMED)
        ctx->state = GS_IDLE;
    ...
}
```

— so a single frame where one finger lands a beat late, or a fifth incidental
contact briefly registers, immediately drops any armed progress back to idle.

A third candidate — AeroSpace's own wrap-around/next-prev cycling logic
(`getNextPrevWorkspace` in AeroSpace's `WorkspaceCommand.swift`) — was
investigated and ruled out: manually reproducing the exact command sequence
`aerospace-swipe` issues (5 iterations of list-workspaces → `workspace next
--wrap-around --stdin`) cycled correctly every time. The problem is upstream
of AeroSpace, in gesture detection.

## Goals

- Fix cross-frame touch identity so per-finger delta comparisons always
  compare the same physical finger to itself.
- Make the finger-count gate tolerant of a single noisy frame instead of
  discarding armed progress immediately.
- Preserve all existing config knobs and their current meaning/defaults
  (`sensitivity`, `swipe_tolerance`, `min_travel`, etc.) — this is a
  correctness fix to the data the thresholds operate on, not a retuning of
  the thresholds themselves.

## Non-goals

- No new user-facing config options in this pass.
- No changes to the AeroSpace-side wrap-around/skip-empty behavior — verified
  working correctly in isolation.
- No change to sensitivity preset values in `apply_sensitivity` (config.h).

## Design

### 1. Stable per-finger slot tracking (`event_tap.h` / `event_tap.m`)

- Add `int slot;` to the `touch` struct (`event_tap.h`).
- Extend the existing per-identity `touch_state` struct (already tracked in
  `touchStates`, keyed by `NSTouch.identity`, used today for velocity
  smoothing) with `int slot;`.
- Maintain a small in-use bitmask (`bool slot_used[MAX_TOUCHES]`, static in
  `event_tap.m`) tracking which of the `MAX_TOUCHES` (16) slots are
  currently assigned.
- In `TouchConverter convert_nstouch:`:
  - On a `touchStates` dictionary miss (new identity): allocate the lowest
    free slot, mark it used, store it in the new `touch_state` entry.
  - On `phase == END_PHASE` (finger lifted): free the slot (mark unused)
    at the same point the existing code already removes the dictionary
    entry.
  - Populate the returned `touch.slot` from the tracked (or newly
    allocated) `touch_state.slot`.

### 2. Index gesture context arrays by slot, not array position (`main.m`)

- Replace every `ctx->prev_x[i]` / `ctx->base_x[i]` read/write in
  `gestureCallback`, `handle_idle_state`, `handle_armed_state`, and
  `handle_committed_state` with `ctx->prev_x[touches[i].slot]` /
  `ctx->base_x[touches[i].slot]`.
- Loop bounds (`for (int i = 0; i < count; ++i)`) are unchanged — `i` still
  walks this frame's touch array in whatever order `NSSet` produced it;
  only the array *used to look up history* changes, from positional to
  identity-derived. `MAX_TOUCHES` already bounds the arrays, and slot values
  are always in range by construction.

### 3. Tolerant finger-count gate (`main.m`)

- Add `int miscount_frames;` to `gesture_ctx`.
- In `gestureCallback`, when `count != g_config.fingers`:
  - If `ctx->state == GS_ARMED`: increment `miscount_frames`. Only drop to
    `GS_IDLE` once `miscount_frames` exceeds a small fixed threshold
    (3 consecutive mismatched frames) rather than immediately on the first
    one. Skip the rest of this frame's processing either way (no averages
    computed, nothing fired) until the count recovers.
  - Otherwise (state `IDLE`): behave as today — reset `prev_x`/`base_x`
    baseline to the current touch positions so a fresh gesture can arm
    cleanly once the right count reappears.
  - Reset `miscount_frames = 0` whenever `count == g_config.fingers`.
- This does not change behavior for a genuine, sustained finger-count
  change (e.g. actually lifting to 2 fingers) — it only survives brief,
  single-frame noise.

## Testing / validation

There's no unit-test harness for the touch/gesture code today (it depends on
live `NSTouch`/`CGEventTap` input), so validation here is manual and
empirical, not automated:

- Build and run `AerospaceSwipe` in the foreground (not as a service) with a
  temporary verbose log line on every `GS_ARMED → GS_IDLE` reset and every
  `fire_gesture` call, showing which check triggered the reset.
- Do a batch of real 4-finger swipes (e.g. 20, left and right) before and
  after the change, comparing how often a swipe fails to fire and, when it
  does fail, whether it was still due to the count gate or the per-finger
  consistency check — this tells us directly whether the identity fix (item
  1/2) is doing the intended work, separately from the count-gate tolerance
  (item 3).
- Confirm no regression in the existing "vertical swipe is correctly
  ignored" and "opposite-direction mid-gesture reversal" behaviors, since
  both depend on the same per-finger arrays this change re-indexes.

## Rollout

- No config schema changes; this is a behavior-only correctness fix.
- Ship as a normal commit once validated; bump to v1.0.1 and re-tag per the
  existing release process (`makefile` `VERSION`, `git tag`, Homebrew
  formula `revision` bump).

## Open question

- The grace-frame threshold (3 consecutive mismatched frames) is a starting
  guess, not derived from measurement. Flag as tunable if testing shows it's
  too loose (spurious fires) or too strict (still resets too eagerly).
