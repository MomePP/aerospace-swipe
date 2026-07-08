# Continuous multi-step swipe model

## Problem

Three related symptoms, all in `src/main.m`'s gesture state machine, on top
of the already-shipped stable-touch-identity fix
(`.claude/specs/gesture-touch-identity-tracking.md`, Tasks 1-4):

1. **"Locked" swipes.** Repeated same-direction swipes (e.g. swipe left 10
   times) eventually stop firing entirely. Recovery only happens after a
   pause or one opposite-direction swipe.
2. **Perceptible lag under rapid swiping.** Workspace changes visibly fall
   behind the physical gesture when swiping quickly, as if AeroSpace itself
   were unresponsive.
3. **Residual misses** even after Tasks 1-4: Task 3 (identity fix) measurably
   helped; Task 4 (tolerant finger-count gate) made no further measurable
   difference, implying the count problem isn't fully solved by tolerating a
   brief miscount — it's that fingers are being undercounted in the first
   place.

## Root cause

### 1. `last_fire_dir` is a one-way latch with no same-direction exit

`fire_gesture` (`src/main.m`):

```c
static void fire_gesture(gesture_ctx* ctx, int direction)
{
	if (direction == ctx->last_fire_dir)
		return;

	ctx->last_fire_dir = direction;
	ctx->state = GS_COMMITTED;
	...
}
```

Once fired, `GS_COMMITTED` has exactly two exits in `handle_committed_state`:
a frame where every currently-reported touch has `phase == END_PHASE` (a
clean full lift), or a reversal (`(dx * ctx->last_fire_dir) < 0`). Repeated
same-direction swiping satisfies neither: real-world staggered finger lifts
between two quick consecutive swipes rarely produce one frame where every
touch is simultaneously `Ended` before the next gesture's touches begin — so
the state machine never leaves `GS_COMMITTED`, and every same-direction
attempt dies in `handle_committed_state`'s reversal check without ever
reaching `fire_gesture` again. A reversal escapes because it satisfies the
other exit; a long pause escapes because it eventually produces a clean lift
frame. This matches the reported symptom exactly.

### 2. Every fired switch is a blocking, unbounded, unthrottled dispatch

`fire_gesture` dispatches onto the global concurrent queue with no cap:

```c
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
	switch_workspace(direction > 0 ? g_config.swipe_right : g_config.swipe_left);
});
```

`switch_workspace` is mutex-serialized but blocks on a socket round-trip —
and with the default config (`wrap_around = true`, `skip_empty = true`,
confirmed in `config.h`), every call does **two** sequential round-trips
(`aerospace_list_workspaces` then `aerospace_workspace`). The connection
itself is persistent (opened once in `aerospace_new`, not reconnected per
call), so this isn't a connection-setup cost — it's pure serialized
round-trip latency with no bound on how many calls can pile up.

Separately, `process_touches` also dispatches each frame's `gestureCallback`
onto the same unordered global concurrent queue. A concurrent queue does not
guarantee FIFO delivery of equal-priority blocks under contention, which
risks frames being processed out of delivery order — significant for any
model that sums displacement across frames.

### 3. Touch counting drops fingers that are merely holding still

`process_touches` builds the per-frame touch buffer by excluding
`NSTouchPhaseStationary` (`(1 << 2)`) touches entirely — not just `Ended`
ones:

```c
if (touch.phase != (1 << 2)) {
	buf[i++] = [TouchConverter convert_nstouch:touch];
}
```

A finger that's momentarily stationary between motion frames — normal,
expected behavior in real human swiping — is silently dropped from that
frame's touch count. This is a more fundamental cause of undercounting than
transient NSSet-ordering noise, and explains why Task 4's tolerate-a-few-
miscounted-frames patch didn't move the needle: the count wasn't briefly
wrong, the counting method itself was structurally excluding valid fingers,
frame after frame.

### Reference implementation comparison

[SwipeAeroSpace](https://github.com/MediosZ/SwipeAeroSpace)
(`SwipeManager.swift`), which the user reports not having these issues with,
avoids all three structurally rather than by patching around them:

- No fire-once-then-lock state. It accumulates total finger displacement
  for the whole gesture (`accDisX`) and derives a quantized target step
  count (`accDisX / threshold`, clamped to `maxSteps`), firing the delta
  between target and already-fired position every time new touch data
  arrives. Swiping further in the same direction is just "target increased
  again" — there's no latch to get stuck in.
- Counts touches by excluding only `.ended`, not `.stationary`.
- Uses a single serial work queue and only ever has one outstanding
  workspace-switch unit of work.

## Goals

- Same-direction repeated swiping fires repeatedly, with no lockout.
- Swiping across more than one workspace's worth of distance in one
  continuous gesture switches multiple workspaces live, matching
  SwipeAeroSpace's multi-step behavior — configurable, not forced on.
- Bound the amount of outstanding workspace-switch work to avoid unbounded
  lag under rapid swiping, without silently dropping a step the user
  actually swiped for.
- Fix touch counting to reflect fingers that are actually down, not just
  fingers that moved this exact frame.
- Preserve the touch-slot identity infrastructure from Tasks 1-3 (still
  needed for accurate per-finger delta averaging) and the existing
  sensitivity/palm-rejection config surface where it still applies.

## Non-goals

- No vertical swipe-up / workspace overview feature (SwipeAeroSpace has one;
  out of scope — not requested, no existing hook for it in this project).
- No change to `aerospace.c`'s socket/handshake layer.
- No change to palm-rejection logic (`is_palm`, `palm_disp`, `palm_age`,
  `palm_velocity`) — untouched, orthogonal to this fix.
- No change to the 4-finger requirement or the general sensitivity-preset
  philosophy in `apply_sensitivity`.

## Design

### 1. Fix finger counting (`src/main.m`, `process_touches`)

Change the filter to exclude only `Ended` touches, matching
SwipeAeroSpace's approach:

```c
if (touch.phase != END_PHASE) {
	buf[i++] = [TouchConverter convert_nstouch:touch];
}
```

A stationary finger now correctly counts as present. This also means
`TouchConverter convert_nstouch:` (and therefore `touch_slot_acquire`) now
runs for stationary touches too — slot assignment is idempotent for an
already-tracked identity, so this is safe.

### 2. Serialize frame processing and workspace switching on one queue

Replace the global-concurrent-queue dispatch in `process_touches` with a
dedicated serial queue (created once, e.g. via `dispatch_queue_create` with
`DISPATCH_QUEUE_SERIAL`), so touch frames are always processed in the order
the event tap delivered them. The workspace-switch dispatch (design item 5
below) uses a separate dedicated serial queue for the same reason — blocking
socket I/O shouldn't share a queue with time-sensitive frame processing.

### 3. Replace the state machine with continuous accumulated displacement

Replace `GS_IDLE` / `GS_ARMED` / `GS_COMMITTED` and `last_fire_dir` with:

```c
typedef enum {
	GS_IDLE,      // no fingers down / gesture not yet started
	GS_TRACKING   // fingers down, accumulating displacement
} gesture_state;

typedef enum {
	AXIS_UNDECIDED,
	AXIS_HORIZONTAL,
	AXIS_VERTICAL
} swipe_axis;

typedef struct {
	gesture_state state;
	swipe_axis axis;
	float start_x, start_y;             // average position at gesture start
	float acc_dx;                       // accumulated horizontal displacement this gesture
	int executed_step;                  // workspace switches actually performed this gesture (signed)
	float prev_x[MAX_TOUCHES], base_x[MAX_TOUCHES]; // unchanged: per-slot history for delta averaging
	bool dispatch_in_flight;            // at most one switch-dispatch outstanding
	char* cached_workspace_list;        // aerospace_list_workspaces() result, reused for this gesture
} gesture_ctx;
```

Per-frame flow in `gestureCallback` (holding `g_gesture_mutex` throughout,
as today):

- `count == 0` → gesture ended. If `g_config.multi_swipe` is off and no step
  fired live yet, fire exactly one step here based on final `acc_dx` sign
  (see item 4). Reset: `acc_dx = 0`, `executed_step = 0`,
  `axis = AXIS_UNDECIDED`, `state = GS_IDLE`, free
  `cached_workspace_list`.
- `count != g_config.fingers` and `state == GS_IDLE`: rebase `prev_x`/
  `base_x` to current positions (unchanged from today), don't arm.
- `count == g_config.fingers` and `state == GS_IDLE`: `state = GS_TRACKING`,
  record `start_x`/`start_y`.
- While `GS_TRACKING`: update `acc_dx` from the per-slot average delta
  (reusing `prev_x`/`base_x`, same averaging approach as today's
  `calculate_touch_averages`). While `axis == AXIS_UNDECIDED`, lock the axis
  once accumulated displacement on either axis crosses a small fraction of
  the configured distance threshold — horizontal if `|acc_dx|` dominates,
  vertical otherwise. Once locked vertical, stop updating `acc_dx` for the
  rest of this gesture (no horizontal fires); this replaces today's
  per-frame `dy > dx * 1.2` re-check with a one-time lock, avoiding a
  diagonal correction mid-swipe from retroactively cancelling an
  already-progressing horizontal gesture.
- Note: unlike today's exact-match-every-frame gate, once `GS_TRACKING`
  starts, a subsequent frame with `count != g_config.fingers` does **not**
  reset progress — it's simply skipped (no `acc_dx` update that frame).
  This is intentionally more permissive than Task 4's grace-frame counter,
  and is expected to make `MISCOUNT_GRACE_FRAMES`/`miscount_frames`
  dead code to be removed, since the finger-count fix in item 1 addresses
  the undercounting at its source.

### 4. Fire steps: live (multi-swipe) or once at release (single-swipe)

When `g_config.multi_swipe` is true, live-fire on every frame the target
changes:

```c
if (ctx->axis == AXIS_HORIZONTAL && g_config.multi_swipe) {
	int target = clamp((int)(ctx->acc_dx / g_config.distance_pct),
	                    -g_config.max_steps, g_config.max_steps);
	if (target != ctx->executed_step)
		maybe_dispatch_switch(ctx);
}
```

When `g_config.multi_swipe` is false, skip live firing entirely; instead,
at gesture end (`count == 0`), fire exactly one step if
`fabsf(ctx->acc_dx) >= g_config.distance_pct`, direction from the sign of
`acc_dx` — this matches SwipeAeroSpace's own single-swipe fallback exactly
(fire once, only on release, no mid-gesture feedback). The existing
fast-flick early-trigger fields (`fast_distance_factor`,
`fast_velocity_threshold`, `min_step_fast`, `min_travel_fast`) keep their
current meaning and apply only to this single-swipe/gesture-end path, where
"a fast decisive swipe counts even if short" remains a meaningful
distinction. They're not used by the live multi-step path, since firing is
already continuous and proportional to distance there — a fast flick
naturally crosses more virtual steps for the same physical distance without
needing a separate early-trigger rule.

### 5. Bounded, lossless dispatch coalescing

Replace the per-fire `dispatch_async` in `fire_gesture` with a single
convergent worker, so at most one dispatch is ever outstanding regardless of
how many times the target changes while it's running:

```c
static void maybe_dispatch_switch(gesture_ctx* ctx)
{
	if (ctx->dispatch_in_flight)
		return; // already converging toward the latest target
	ctx->dispatch_in_flight = true;

	dispatch_async(g_workspace_queue, ^{
		for (;;) {
			pthread_mutex_lock(&g_gesture_mutex);
			int target = clamp((int)(ctx->acc_dx / g_config.distance_pct),
			                    -g_config.max_steps, g_config.max_steps);
			int delta = target - ctx->executed_step;
			pthread_mutex_unlock(&g_gesture_mutex);

			if (delta == 0)
				break;

			int step_dir = delta > 0 ? 1 : -1;
			switch_workspace(step_dir > 0 ? g_config.swipe_right : g_config.swipe_left,
			                  ctx); // reuses/populates ctx->cached_workspace_list

			pthread_mutex_lock(&g_gesture_mutex);
			ctx->executed_step += step_dir;
			pthread_mutex_unlock(&g_gesture_mutex);
		}
		pthread_mutex_lock(&g_gesture_mutex);
		ctx->dispatch_in_flight = false;
		pthread_mutex_unlock(&g_gesture_mutex);
	});
}
```

This deliberately supersedes the "drop excess fires" framing discussed
earlier in favor of a design that achieves the same responsiveness without
ever silently discarding a step: `workspace next/prev` are relative
commands, so a dropped intermediate step is a permanently wrong final
position, not just a skipped animation frame. Because at most one dispatch
runs at a time and it always re-reads the true current target, the backlog
is naturally bounded by `max_steps` (the worst case is draining a full
`max_steps`-sized swing, a handful of fast sequential round-trips — not an
ever-growing queue), and every step the user actually swiped for still
executes. Flagging this explicitly since it changes the mechanism from what
was proposed when the drop-vs-queue question was first asked — please say
if you'd rather keep the literal drop-excess behavior instead.

### 6. Cache the workspace list once per gesture

`switch_workspace` currently re-fetches `aerospace_list_workspaces` on
every call when `skip_empty` or `wrap_around` is set. With multi-step
firing, a single gesture can now call `switch_workspace` up to `max_steps`
times. Thread `ctx->cached_workspace_list` through: fetch once, on the
first `switch_workspace` call of a gesture, and reuse it for subsequent
calls within the same gesture; free and clear it on gesture reset (`count
== 0`). Window-to-workspace assignment doesn't change from focus-switching
alone, so reusing the snapshot for the duration of one continuous gesture
is correct, not just an optimization that happens to look right.

### 7. New config

`Config` (`src/config.h`) gains:

```c
bool multi_swipe; // default true
int max_steps;    // default 5, only relevant when multi_swipe is true
```

With JSON parsing entries mirroring the existing `wrap_around`/`skip_empty`
bool and `swipe_tolerance` int patterns. Both are user-adjustable, matching
SwipeAeroSpace's `multiSwipeEnabled`/`maxSteps` settings.

## Testing / validation

Same constraint as the prior spec: no unit-test harness for live
`NSTouch`/`CGEventTap` input, so this is manual/empirical:

- Build and run `AerospaceSwipe` in the foreground with temporary logging on
  every `switch_workspace` call (direction, `ctx->acc_dx`, `ctx->executed_step`)
  to directly observe convergence during rapid swiping.
- Reproduce the original "locked" repro (10+ same-direction swipes in a
  row) and confirm every one fires.
- Rapid repeated swiping: confirm workspace changes keep pace with physical
  swipes rather than visibly catching up afterward.
- A single continuous swipe covering more than one workspace's worth of
  distance: confirm it switches multiple workspaces live, capped at
  `max_steps`.
- Set `multi_swipe: false`: confirm behavior reverts to one switch per
  gesture, firing only on release.
- Confirm vertical gestures (e.g. accidental Mission Control swipe) are
  still correctly ignored for workspace switching, and that a diagonal
  correction after horizontal axis-lock doesn't cancel an in-progress
  horizontal swipe.
- Confirm no regression in the finger-count tolerance validated by Tasks
  1-3 (per-finger identity fix) — this spec's item 1 change is expected to
  make Task 4's grace-frame counter unreachable/dead code; remove it as part
  of this work rather than leaving unreachable code behind.

## Rollout

- Config schema change (new `multi_swipe`/`max_steps` keys, both with safe
  defaults) — existing config files without these keys keep working
  unchanged.
- Continue on the existing `gesture-touch-identity-tracking` branch, since
  this directly rewrites the gesture-callback code Tasks 3-4 touched; no new
  branch/worktree.
- Ship as part of the same v1.0.1 release and Homebrew formula
  `tag:`/`revision:` bump already planned (Task 5 of the prior plan).

## Open questions

- `max_steps` default of 5 and the axis-lock threshold fraction are carried
  over from SwipeAeroSpace's tuning, not independently derived — flag as
  tunable if testing shows the feel is off.
- Item 5's dispatch design intentionally changes the earlier-agreed
  "drop excess, stay responsive" answer to a lossless convergent-worker
  design; called out above for confirmation during spec review rather than
  re-asked as a blocking question, since it satisfies the same
  responsiveness goal without the downside.
