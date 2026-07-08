# Continuous Multi-Step Swipe Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace aerospace-swipe's IDLE/ARMED/COMMITTED lock-on-fire gesture
state machine with a continuous accumulated-displacement model that fires
one or more workspace switches live as a 4-finger swipe progresses,
eliminating the same-direction "lockout" bug and the unbounded dispatch
backlog under rapid swiping.

**Architecture:** A gesture accumulates horizontal displacement
(`gesture_ctx.acc_dx`) for as long as fingers stay down. Two new pure
functions in a new `src/gesture_math.h`/`.c` (`compute_target_step`,
`decide_axis`) turn that displacement into a target step count and an
axis decision. `gestureCallback` (`src/main.m`) fires the delta between
target and executed steps live when `multi_swipe` is on, or once at
release when it's off. A bounded, lossless dispatch worker
(`maybe_dispatch_switch`) guarantees at most one outstanding
workspace-switch unit of work regardless of swipe speed.

**Tech Stack:** C99 (gesture math, config), Objective-C (event tap,
gesture callback, dispatch), GCD (`dispatch_queue_t`, serial queues),
existing `aerospace.c` socket client (untouched).

## Global Constraints

- 4-finger swipes only; no config or code change to the finger-count
  requirement itself (per prior explicit decision: 3 fingers conflicts
  with macOS's 3-finger drag).
- No change to `src/aerospace.c`'s socket/handshake layer.
- No change to palm-rejection logic (`is_palm`, `palm_disp`, `palm_age`,
  `palm_velocity`).
- New config keys (`multi_swipe`, `max_steps`) must have safe defaults so
  existing config files without them keep working unchanged:
  `multi_swipe` defaults to `true`, `max_steps` defaults to `5`.
- `multi_swipe: false` fires exactly one step, only at gesture release
  (all fingers lifted) — no live mid-gesture feedback in that mode. This
  matches SwipeAeroSpace's own single-swipe fallback exactly, per explicit
  decision during design.
- The dispatch-coalescing mechanism must never silently drop a step the
  user actually swiped for (`workspace next/prev` are relative commands —
  a dropped step is a permanently wrong final position, not a skipped
  animation frame). At most one dispatch may be outstanding at a time.
- Remove config fields and `#define`s that this rewrite makes unreachable
  (`swipe_tolerance`, `velocity_pct`, `min_step`, `min_travel`,
  `min_step_fast`, `min_travel_fast`, `FAST_VEL_FACTOR`) — per this
  project's "remove imports/variables/functions your changes made unused"
  rule. Do **not** remove `settle_factor` — it is already unused in the
  current code, predates this change, and removing it is out of scope
  (surgical changes: mention pre-existing dead code, don't delete it).
- Preserve the touch-slot identity infrastructure from the prior plan
  (`touch_slot_acquire`/`touch_slot_release`, `touch.slot`,
  `MAX_TOUCHES`) — still needed for accurate per-finger delta averaging.
  Do not touch `event_tap.m`'s slot allocator.

---

### Task 1: Gesture math helpers + unit tests

**Files:**
- Create: `src/gesture_math.h`
- Create: `src/gesture_math.c`
- Create: `test/test_gesture_math.c`
- Modify: `makefile`

**Interfaces:**
- Produces: `typedef enum { AXIS_UNDECIDED, AXIS_HORIZONTAL, AXIS_VERTICAL } swipe_axis;`
- Produces: `int compute_target_step(float acc_dx, float distance_pct, int max_steps);`
  — truncates `acc_dx / distance_pct` toward zero, clamps to
  `[-max_steps, max_steps]`.
- Produces: `swipe_axis decide_axis(float dx, float dy, float lock_threshold);`
  — returns `AXIS_UNDECIDED` while both `|dx|` and `|dy|` are below
  `lock_threshold`; otherwise `AXIS_VERTICAL` if `|dy| > |dx|`, else
  `AXIS_HORIZONTAL` (ties go to horizontal).
- Consumes: nothing (pure functions, no project dependencies beyond
  `<math.h>`).

These two functions are used by Task 4's gesture rewrite in `src/main.m`,
but are pure C with no Cocoa/touch dependency, so they're unit-testable in
isolation — following the same pattern the prior plan used for
`touch_slot_acquire` (`test/test_touch_slots.m`, built as its own binary
via `make test`).

- [ ] **Step 1: Write the failing tests**

Create `test/test_gesture_math.c`:

```c
#include "../src/gesture_math.h"
#include <assert.h>
#include <stdio.h>

static void test_compute_target_step_zero(void)
{
	assert(compute_target_step(0.0f, 0.08f, 5) == 0);
}

static void test_compute_target_step_below_threshold(void)
{
	assert(compute_target_step(0.05f, 0.08f, 5) == 0);
}

static void test_compute_target_step_one_positive_step(void)
{
	assert(compute_target_step(0.09f, 0.08f, 5) == 1);
}

static void test_compute_target_step_one_negative_step(void)
{
	assert(compute_target_step(-0.09f, 0.08f, 5) == -1);
}

static void test_compute_target_step_multiple_steps(void)
{
	assert(compute_target_step(0.25f, 0.08f, 5) == 3);
}

static void test_compute_target_step_clamped_at_max(void)
{
	assert(compute_target_step(10.0f, 0.08f, 5) == 5);
	assert(compute_target_step(-10.0f, 0.08f, 5) == -5);
}

static void test_decide_axis_undecided_below_threshold(void)
{
	assert(decide_axis(0.01f, 0.01f, 0.05f) == AXIS_UNDECIDED);
}

static void test_decide_axis_horizontal(void)
{
	assert(decide_axis(0.10f, 0.02f, 0.05f) == AXIS_HORIZONTAL);
}

static void test_decide_axis_vertical(void)
{
	assert(decide_axis(0.02f, 0.10f, 0.05f) == AXIS_VERTICAL);
}

static void test_decide_axis_equal_magnitude_prefers_horizontal(void)
{
	assert(decide_axis(0.10f, 0.10f, 0.05f) == AXIS_HORIZONTAL);
}

int main(void)
{
	test_compute_target_step_zero();
	test_compute_target_step_below_threshold();
	test_compute_target_step_one_positive_step();
	test_compute_target_step_one_negative_step();
	test_compute_target_step_multiple_steps();
	test_compute_target_step_clamped_at_max();
	test_decide_axis_undecided_below_threshold();
	test_decide_axis_horizontal();
	test_decide_axis_vertical();
	test_decide_axis_equal_magnitude_prefers_horizontal();
	printf("All gesture_math tests passed.\n");
	return 0;
}
```

- [ ] **Step 2: Create the header**

Create `src/gesture_math.h`:

```c
#pragma once

typedef enum {
	AXIS_UNDECIDED,
	AXIS_HORIZONTAL,
	AXIS_VERTICAL
} swipe_axis;

// Clamped, truncated-toward-zero target step count for the given
// accumulated horizontal displacement. distance_pct must be > 0.
int compute_target_step(float acc_dx, float distance_pct, int max_steps);

// Decides whether accumulated displacement should lock the swipe axis to
// horizontal or vertical, or remain undecided. lock_threshold is the
// magnitude (on whichever axis) that must be crossed before locking.
swipe_axis decide_axis(float dx, float dy, float lock_threshold);
```

- [ ] **Step 3: Try to build the test — verify it fails to link**

Run: `cd /Users/momeppkt/Developer/aerospace-swipe/.worktrees/gesture-touch-identity-tracking && clang -std=c99 -O0 -g -Wall -Wextra -o /tmp/test_gesture_math test/test_gesture_math.c -lm`
Expected: FAIL — undefined symbols `_compute_target_step`, `_decide_axis`
(no `.c` implementation exists yet).

- [ ] **Step 4: Write the implementation**

Create `src/gesture_math.c`:

```c
#include "gesture_math.h"
#include <math.h>

int compute_target_step(float acc_dx, float distance_pct, int max_steps)
{
	int target = (int)(acc_dx / distance_pct);
	if (target > max_steps)
		target = max_steps;
	if (target < -max_steps)
		target = -max_steps;
	return target;
}

swipe_axis decide_axis(float dx, float dy, float lock_threshold)
{
	if (fabsf(dx) < lock_threshold && fabsf(dy) < lock_threshold)
		return AXIS_UNDECIDED;
	return fabsf(dy) > fabsf(dx) ? AXIS_VERTICAL : AXIS_HORIZONTAL;
}
```

- [ ] **Step 5: Wire the test into the makefile and run it**

In `makefile`, change:

```makefile
SRC_FILES = src/aerospace.c src/yyjson.c src/haptic.c src/event_tap.m src/main.m
```

to:

```makefile
SRC_FILES = src/aerospace.c src/yyjson.c src/haptic.c src/gesture_math.c src/event_tap.m src/main.m
```

Change:

```makefile
TEST_TARGET = test_touch_slots

test: $(TEST_TARGET)
	./$(TEST_TARGET)

$(TEST_TARGET): src/event_tap.m test/test_touch_slots.m
	$(CC) $(CFLAGS) $(ARCH) -o $(TEST_TARGET) src/event_tap.m test/test_touch_slots.m $(FRAMEWORKS) $(LDLIBS)
```

to:

```makefile
TEST_TARGET = test_touch_slots
GESTURE_MATH_TEST_TARGET = test_gesture_math

test: $(TEST_TARGET) $(GESTURE_MATH_TEST_TARGET)
	./$(TEST_TARGET)
	./$(GESTURE_MATH_TEST_TARGET)

$(TEST_TARGET): src/event_tap.m test/test_touch_slots.m
	$(CC) $(CFLAGS) $(ARCH) -o $(TEST_TARGET) src/event_tap.m test/test_touch_slots.m $(FRAMEWORKS) $(LDLIBS)

$(GESTURE_MATH_TEST_TARGET): src/gesture_math.c test/test_gesture_math.c
	$(CC) -std=c99 -O0 -g -Wall -Wextra -o $(GESTURE_MATH_TEST_TARGET) src/gesture_math.c test/test_gesture_math.c -lm
```

And change:

```makefile
clean:
	rm -rf $(TARGET) $(APP_BUNDLE) $(TEST_TARGET)
```

to:

```makefile
clean:
	rm -rf $(TARGET) $(APP_BUNDLE) $(TEST_TARGET) $(GESTURE_MATH_TEST_TARGET)
```

Run: `cd /Users/momeppkt/Developer/aerospace-swipe/.worktrees/gesture-touch-identity-tracking && make test`
Expected: both `test_touch_slots` and `test_gesture_math` build and print
their "All ... tests passed." lines, exit code 0.

- [ ] **Step 6: Gitignore the new test binary**

Add to `.gitignore` (alongside the existing `test_touch_slots` entry):

```
test_gesture_math
```

- [ ] **Step 7: Commit**

```bash
git add src/gesture_math.h src/gesture_math.c test/test_gesture_math.c makefile .gitignore
git commit -m "feat: add pure gesture-math helpers (target step, axis decision) with unit tests"
```

---

### Task 2: Fix finger counting and serialize frame processing

**Files:**
- Modify: `src/main.m` (`process_touches`, and the globals section near the
  top of the file)

**Interfaces:**
- Consumes: `END_PHASE` (already defined in `src/event_tap.h` as `8`).
- Produces: `static dispatch_queue_t g_gesture_queue;` — a serial queue
  later tasks' code must not need to know about beyond this file (frame
  dispatch stays internal to `process_touches`/`key_handler`).

**Context:** `process_touches` currently excludes
`NSTouchPhaseStationary` touches entirely, which drops a finger that's
merely holding still for one frame — normal during real swiping, and the
dominant remaining cause of undercounted fingers even after the prior
plan's Task 3/4 fixes. It also dispatches each frame onto the unordered
global concurrent queue, which doesn't guarantee frames are processed in
delivery order — important once gesture math starts summing displacement
across frames (Task 4).

- [ ] **Step 1: Add the serial gesture-processing queue**

In `src/main.m`, find this block near the top of the file:

```c
static aerospace* g_aerospace = NULL;
static CFTypeRef g_haptic = NULL;
static Config g_config;
static pthread_mutex_t g_gesture_mutex = PTHREAD_MUTEX_INITIALIZER;
static gesture_ctx g_gesture_ctx = { 0 };
static CFMutableDictionaryRef g_tracks = NULL;
```

Replace it with:

```c
static aerospace* g_aerospace = NULL;
static CFTypeRef g_haptic = NULL;
static Config g_config;
static pthread_mutex_t g_gesture_mutex = PTHREAD_MUTEX_INITIALIZER;
static gesture_ctx g_gesture_ctx = { 0 };
static CFMutableDictionaryRef g_tracks = NULL;

// Frames are dispatched here in delivery order, one at a time — required
// since gesture processing sums displacement across frames and a
// concurrent queue does not guarantee FIFO delivery under contention.
static dispatch_queue_t g_gesture_queue;
```

- [ ] **Step 2: Initialize the queue in `main()`**

In `src/main.m`, find this line inside `main()`:

```c
		g_tracks = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);

		event_tap_begin(&g_event_tap, key_handler);
```

Replace it with:

```c
		g_tracks = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);

		g_gesture_queue = dispatch_queue_create("aerospace-swipe.gesture", DISPATCH_QUEUE_SERIAL);

		event_tap_begin(&g_event_tap, key_handler);
```

- [ ] **Step 3: Fix the touch filter and use the serial queue**

In `src/main.m`, find `process_touches`:

```c
static void process_touches(NSSet<NSTouch*>* touches)
{
	NSUInteger buf_capacity = touches.count > 0 ? touches.count : 4;
	touch* buf = malloc(sizeof(touch) * buf_capacity);
	NSUInteger i = 0;

	for (NSTouch* touch in touches) {
		if (touch.phase != (1 << 2)) {
			if (i >= buf_capacity) {
				buf_capacity *= 2;
				buf = realloc(buf, sizeof(touch) * buf_capacity);
			}
			buf[i++] = [TouchConverter convert_nstouch:touch];
		}
	}

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		gestureCallback(buf, (int)i);
		free(buf);
	});
}
```

Replace it with:

```c
static void process_touches(NSSet<NSTouch*>* touches)
{
	NSUInteger buf_capacity = touches.count > 0 ? touches.count : 4;
	touch* buf = malloc(sizeof(touch) * buf_capacity);
	NSUInteger i = 0;

	for (NSTouch* touch in touches) {
		if (touch.phase != END_PHASE) {
			if (i >= buf_capacity) {
				buf_capacity *= 2;
				buf = realloc(buf, sizeof(touch) * buf_capacity);
			}
			buf[i++] = [TouchConverter convert_nstouch:touch];
		}
	}

	dispatch_async(g_gesture_queue, ^{
		gestureCallback(buf, (int)i);
		free(buf);
	});
}
```

- [ ] **Step 4: Build**

Run: `cd /Users/momeppkt/Developer/aerospace-swipe/.worktrees/gesture-touch-identity-tracking && make clean && make all`
Expected: builds with no errors (Task 4 still needs to land before the
touch-count fix is exercised by the new gesture model, but this must
compile cleanly against the existing state machine in the meantime, since
neither the filter change nor the queue change alter any type or
signature the existing `gestureCallback` depends on).

- [ ] **Step 5: Manual validation note**

No automated test is possible here — gesture correctness depends on live
`NSTouch`/`CGEventTap` input, same constraint as the rest of this
codebase's gesture logic. Validation happens as part of Task 4's manual
swipe testing, once the new firing model can actually show the effect of
counting stationary fingers correctly.

- [ ] **Step 6: Commit**

```bash
git add src/main.m
git commit -m "fix: count stationary touches, serialize gesture frame dispatch"
```

---

### Task 3: Config additions for multi-step swiping

**Files:**
- Modify: `src/config.h`
- Modify: `src/main.m` (startup config-summary log line only)
- Test: `test/test_config.c`
- Modify: `makefile`

**Interfaces:**
- Produces: `Config.multi_swipe` (`bool`, default `true`).
- Produces: `Config.max_steps` (`int`, default `5`).
- Consumes: nothing new — mirrors the existing `wrap_around`/`skip_empty`
  bool and `swipe_tolerance` int JSON-parsing patterns already in
  `load_config()`.

This task only **adds** fields — it must not remove or touch
`swipe_tolerance`/`velocity_pct`/`min_step`/`min_travel`/etc., since the
current (pre-Task-4) gesture code in `src/main.m` still reads them. Task 4
removes those once its rewrite makes them unreachable.

- [ ] **Step 1: Write the failing test**

Create `test/test_config.c`:

```c
#include "../src/config.h"
#include <assert.h>
#include <stdio.h>

static void test_default_config_multi_swipe(void)
{
	Config config = default_config();
	assert(config.multi_swipe == true);
	assert(config.max_steps == 5);
}

int main(void)
{
	test_default_config_multi_swipe();
	printf("All config tests passed.\n");
	return 0;
}
```

- [ ] **Step 2: Try to build the test — verify it fails**

Run: `cd /Users/momeppkt/Developer/aerospace-swipe/.worktrees/gesture-touch-identity-tracking && clang -std=c99 -O0 -g -Wall -Wextra -framework CoreFoundation -o /tmp/test_config src/yyjson.c test/test_config.c -lm`
Expected: FAIL — `error: no member named 'multi_swipe' in 'Config'` (and
`max_steps`).

- [ ] **Step 3: Add the fields to `Config`**

In `src/config.h`, find:

```c
	float fast_distance_factor;   // For fast swipes, trigger at this fraction of distance_pct
	float fast_velocity_threshold; // Minimum velocity to qualify as "fast"
	const char* swipe_left;
	const char* swipe_right;
} Config;
```

Replace it with:

```c
	float fast_distance_factor;   // For fast swipes, trigger at this fraction of distance_pct
	float fast_velocity_threshold; // Minimum velocity to qualify as "fast"
	bool multi_swipe;    // fire multiple workspace switches within one continuous gesture
	int max_steps;       // cap on workspaces crossed per gesture when multi_swipe is on
	const char* swipe_left;
	const char* swipe_right;
} Config;
```

- [ ] **Step 4: Set the defaults**

In `src/config.h`, find:

```c
	config.fast_distance_factor = 0.60f;   // Fast swipes can trigger at 60% of normal distance
	config.fast_velocity_threshold = 0.35f; // Velocity needed for fast-trigger
	config.swipe_left = "prev";
```

Replace it with:

```c
	config.fast_distance_factor = 0.60f;   // Fast swipes can trigger at 60% of normal distance
	config.fast_velocity_threshold = 0.35f; // Velocity needed for fast-trigger
	config.multi_swipe = true;
	config.max_steps = 5;
	config.swipe_left = "prev";
```

- [ ] **Step 5: Run the test — verify it passes**

Run: `cd /Users/momeppkt/Developer/aerospace-swipe/.worktrees/gesture-touch-identity-tracking && clang -std=c99 -O0 -g -Wall -Wextra -framework CoreFoundation -o /tmp/test_config src/yyjson.c test/test_config.c -lm && /tmp/test_config`
Expected: PASS, prints "All config tests passed."

- [ ] **Step 6: Add JSON parsing**

In `src/config.h`, find:

```c
	// Sensitivity can be set via JSON (1-5), overrides distance/velocity
	item = yyjson_obj_get(root, "sensitivity");
	if (item && yyjson_is_int(item)) {
		apply_sensitivity(&config, (int)yyjson_get_int(item));
	}
```

Replace it with:

```c
	// Sensitivity can be set via JSON (1-5), overrides distance/velocity
	item = yyjson_obj_get(root, "sensitivity");
	if (item && yyjson_is_int(item)) {
		apply_sensitivity(&config, (int)yyjson_get_int(item));
	}

	item = yyjson_obj_get(root, "multi_swipe");
	if (item && yyjson_is_bool(item))
		config.multi_swipe = yyjson_get_bool(item);

	item = yyjson_obj_get(root, "max_steps");
	if (item && yyjson_is_int(item))
		config.max_steps = (int)yyjson_get_int(item);
```

- [ ] **Step 7: Log the new fields at startup for visual confirmation**

In `src/main.m`, find:

```c
		g_config = load_config();
		NSLog(@"Loaded config: fingers=%d, skip_empty=%s, wrap_around=%s, haptic=%s, swipe_left='%s', swipe_right='%s'",
			g_config.fingers,
			g_config.skip_empty ? "YES" : "NO",
			g_config.wrap_around ? "YES" : "NO",
			g_config.haptic ? "YES" : "NO",
			g_config.swipe_left,
			g_config.swipe_right);
```

Replace it with:

```c
		g_config = load_config();
		NSLog(@"Loaded config: fingers=%d, skip_empty=%s, wrap_around=%s, haptic=%s, multi_swipe=%s, max_steps=%d, swipe_left='%s', swipe_right='%s'",
			g_config.fingers,
			g_config.skip_empty ? "YES" : "NO",
			g_config.wrap_around ? "YES" : "NO",
			g_config.haptic ? "YES" : "NO",
			g_config.multi_swipe ? "YES" : "NO",
			g_config.max_steps,
			g_config.swipe_left,
			g_config.swipe_right);
```

- [ ] **Step 8: Wire the config test into the makefile and run everything**

In `makefile`, find (as left by Task 1):

```makefile
test: $(TEST_TARGET) $(GESTURE_MATH_TEST_TARGET)
	./$(TEST_TARGET)
	./$(GESTURE_MATH_TEST_TARGET)
```

Replace it with:

```makefile
test: $(TEST_TARGET) $(GESTURE_MATH_TEST_TARGET) $(CONFIG_TEST_TARGET)
	./$(TEST_TARGET)
	./$(GESTURE_MATH_TEST_TARGET)
	./$(CONFIG_TEST_TARGET)
```

In `makefile`, find:

```makefile
TEST_TARGET = test_touch_slots
GESTURE_MATH_TEST_TARGET = test_gesture_math
```

Replace it with:

```makefile
TEST_TARGET = test_touch_slots
GESTURE_MATH_TEST_TARGET = test_gesture_math
CONFIG_TEST_TARGET = test_config
```

In `makefile`, find:

```makefile
$(GESTURE_MATH_TEST_TARGET): src/gesture_math.c test/test_gesture_math.c
	$(CC) -std=c99 -O0 -g -Wall -Wextra -o $(GESTURE_MATH_TEST_TARGET) src/gesture_math.c test/test_gesture_math.c -lm
```

Replace it with:

```makefile
$(GESTURE_MATH_TEST_TARGET): src/gesture_math.c test/test_gesture_math.c
	$(CC) -std=c99 -O0 -g -Wall -Wextra -o $(GESTURE_MATH_TEST_TARGET) src/gesture_math.c test/test_gesture_math.c -lm

$(CONFIG_TEST_TARGET): src/yyjson.c test/test_config.c
	$(CC) -std=c99 -O0 -g -Wall -Wextra -framework CoreFoundation -o $(CONFIG_TEST_TARGET) src/yyjson.c test/test_config.c -lm
```

In `makefile`, find:

```makefile
clean:
	rm -rf $(TARGET) $(APP_BUNDLE) $(TEST_TARGET) $(GESTURE_MATH_TEST_TARGET)
```

Replace it with:

```makefile
clean:
	rm -rf $(TARGET) $(APP_BUNDLE) $(TEST_TARGET) $(GESTURE_MATH_TEST_TARGET) $(CONFIG_TEST_TARGET)
```

Add to `.gitignore`:

```
test_config
```

Run: `cd /Users/momeppkt/Developer/aerospace-swipe/.worktrees/gesture-touch-identity-tracking && make test && make clean && make all`
Expected: all three test binaries pass; the full app still builds cleanly
(this task doesn't remove anything the current gesture code needs).

- [ ] **Step 9: Commit**

```bash
git add src/config.h src/main.m test/test_config.c makefile .gitignore
git commit -m "feat: add multi_swipe/max_steps config options"
```

---

### Task 4: Replace the gesture state machine with continuous multi-step firing

**Files:**
- Modify: `src/event_tap.h` (gesture state/context types, dead `#define`
  removal)
- Modify: `src/config.h` (remove fields orphaned by this rewrite)
- Modify: `src/main.m` (`switch_workspace`, gesture logic functions,
  `gestureCallback`, globals, `main()`)

**Interfaces:**
- Consumes: `compute_target_step`, `decide_axis`, `swipe_axis` (Task 1);
  `g_config.multi_swipe`, `g_config.max_steps` (Task 3); `END_PHASE`,
  `g_gesture_queue` (Task 2, unchanged by this task).
- Produces: `static void switch_workspace(const char* ws, char** cached_workspaces);`
  — signature change from the current single-argument form. All callers
  in this file are updated by this task; no other file calls it.
- Produces: `static dispatch_queue_t g_workspace_queue;` — serial queue
  dedicated to blocking workspace-switch socket I/O, separate from
  `g_gesture_queue`.

This is the core of the plan — it replaces `GS_IDLE`/`GS_ARMED`/
`GS_COMMITTED` and `last_fire_dir` with `GS_IDLE`/`GS_TRACKING` plus
continuously accumulated displacement, and replaces the per-fire
`dispatch_async` onto the global queue with a bounded convergent worker.
No automated test is possible for this task (depends on live
`NSTouch`/`CGEventTap` input, same constraint noted in the prior plan) —
validation is manual, detailed in Step 8.

- [ ] **Step 1: Remove config fields this rewrite orphans**

In `src/config.h`, find:

```c
	bool natural_swipe;
	bool wrap_around;
	bool haptic;
	bool skip_empty;
	bool show_menu_bar;
	int fingers;
	int swipe_tolerance;
	int sensitivity;      // 1-5 scale, affects distance_pct and velocity_pct
	float distance_pct;   // distance
	float velocity_pct;   // velocity
	float settle_factor;
	float min_step;
	float min_travel;
	float min_step_fast;
	float min_travel_fast;
	float palm_disp;
```

Replace it with:

```c
	bool natural_swipe;
	bool wrap_around;
	bool haptic;
	bool skip_empty;
	bool show_menu_bar;
	int fingers;
	int sensitivity;      // 1-5 scale, affects distance_pct
	float distance_pct;   // distance
	float settle_factor;  // unused by current gesture logic; left as-is, predates this change
	float palm_disp;
```

(`swipe_tolerance`, `velocity_pct`, `min_step`, `min_travel`,
`min_step_fast`, `min_travel_fast` are only read by the state-machine code
this task removes in Step 5. `settle_factor` is already unused before this
task — leave it untouched.)

In `src/config.h`, find:

```c
static void apply_sensitivity(Config* config, int level)
{
	config->sensitivity = level;

	// Velocity threshold for arming logic
	config->velocity_pct = 0.10f;

	// 3 levels: 1=Low, 2=Medium, 3=High
	switch (level) {
		case 1: // Low - requires ~35% trackpad swipe, or 60% if fast
			config->distance_pct = 0.35f;
			config->min_travel = 0.060f;
			config->fast_distance_factor = 0.60f;     // 21% of trackpad if fast
			config->fast_velocity_threshold = 0.45f;  // Higher velocity needed
			break;
		case 2: // Medium - requires ~20% trackpad swipe, or 60% if fast
			config->distance_pct = 0.20f;
			config->min_travel = 0.035f;
			config->fast_distance_factor = 0.60f;     // 12% of trackpad if fast
			config->fast_velocity_threshold = 0.35f;  // Moderate velocity required
			break;
		case 3: // High - requires ~8% trackpad swipe, or 60% if fast
		default:
			config->distance_pct = 0.08f;
			config->min_travel = 0.015f;
			config->fast_distance_factor = 0.60f;     // ~5% of trackpad if fast
			config->fast_velocity_threshold = 0.25f;  // Lower velocity needed
			break;
	}
}
```

Replace it with:

```c
static void apply_sensitivity(Config* config, int level)
{
	config->sensitivity = level;

	// 3 levels: 1=Low, 2=Medium, 3=High
	switch (level) {
		case 1: // Low - requires ~35% trackpad swipe, or 60% if fast
			config->distance_pct = 0.35f;
			config->fast_distance_factor = 0.60f;     // 21% of trackpad if fast
			config->fast_velocity_threshold = 0.45f;  // Higher velocity needed
			break;
		case 2: // Medium - requires ~20% trackpad swipe, or 60% if fast
			config->distance_pct = 0.20f;
			config->fast_distance_factor = 0.60f;     // 12% of trackpad if fast
			config->fast_velocity_threshold = 0.35f;  // Moderate velocity required
			break;
		case 3: // High - requires ~8% trackpad swipe, or 60% if fast
		default:
			config->distance_pct = 0.08f;
			config->fast_distance_factor = 0.60f;     // ~5% of trackpad if fast
			config->fast_velocity_threshold = 0.25f;  // Lower velocity needed
			break;
	}
}
```

In `src/config.h`, find:

```c
	config.natural_swipe = false;
	config.wrap_around = true;
	config.haptic = false;
	config.skip_empty = true;
	config.show_menu_bar = true;
	config.fingers = 3;
	config.swipe_tolerance = 2;      // Allow up to 2 fingers to mismatch
	config.sensitivity = 2;          // Default sensitivity level (1=Low, 2=Medium, 3=High)
	config.settle_factor = 0.25f;    // ≤25% of flick speed -> ended
	config.min_step = 0.006f;        // Step threshold
	config.min_step_fast = 0.0f;
	config.min_travel_fast = 0.003f; // Fast swipe threshold
	config.palm_disp = 0.025;        // 2.5% pad from origin
```

Replace it with:

```c
	config.natural_swipe = false;
	config.wrap_around = true;
	config.haptic = false;
	config.skip_empty = true;
	config.show_menu_bar = true;
	config.fingers = 3;
	config.sensitivity = 2;          // Default sensitivity level (1=Low, 2=Medium, 3=High)
	config.settle_factor = 0.25f;    // ≤25% of flick speed -> ended (unused, predates this change)
	config.palm_disp = 0.025;        // 2.5% pad from origin
```

In `src/config.h`, find:

```c
	item = yyjson_obj_get(root, "swipe_tolerance");
	if (item && yyjson_is_int(item))
		config.swipe_tolerance = (int)yyjson_get_int(item);

	item = yyjson_obj_get(root, "distance_pct");
	if (item && yyjson_is_real(item))
		config.distance_pct = (float)yyjson_get_real(item);

	item = yyjson_obj_get(root, "velocity_pct");
	if (item && yyjson_is_real(item))
		config.velocity_pct = (float)yyjson_get_real(item);

	item = yyjson_obj_get(root, "settle_factor");
```

Replace it with:

```c
	item = yyjson_obj_get(root, "distance_pct");
	if (item && yyjson_is_real(item))
		config.distance_pct = (float)yyjson_get_real(item);

	item = yyjson_obj_get(root, "settle_factor");
```

- [ ] **Step 2: Rebuild `test_config` and confirm it still passes**

Run: `cd /Users/momeppkt/Developer/aerospace-swipe/.worktrees/gesture-touch-identity-tracking && make test_config && ./test_config`
Expected: PASS (Task 3's test only asserts on `multi_swipe`/`max_steps`,
untouched by this removal).

- [ ] **Step 3: Replace the gesture state/context types**

In `src/event_tap.h`, find:

```c
#define ACTIVATE_PCT 0.05f
#define END_PHASE 8 // NSTouchPhaseEnded
#define FAST_VEL_FACTOR 0.80f
#define MISCOUNT_GRACE_FRAMES 3 // consecutive wrong-count frames tolerated while armed before resetting
#define MAX_TOUCHES 16
```

Replace it with:

```c
#include "gesture_math.h"

#define ACTIVATE_PCT 0.05f
#define END_PHASE 8 // NSTouchPhaseEnded
#define MAX_TOUCHES 16
```

In `src/event_tap.h`, find:

```c
// Gesture state enumeration
typedef enum {
	GS_IDLE,
	GS_ARMED,
	GS_COMMITTED
} gesture_state;

// Gesture context structure
typedef struct {
	gesture_state state;
	float start_x, start_y, peak_velx;
	int dir, last_fire_dir;
	float prev_x[MAX_TOUCHES], base_x[MAX_TOUCHES];
	int miscount_frames; // consecutive frames where touch count != g_config.fingers while GS_ARMED
} gesture_ctx;
```

Replace it with:

```c
// Gesture state enumeration
typedef enum {
	GS_IDLE,      // no fingers down / gesture not yet started
	GS_TRACKING   // fingers down, accumulating displacement
} gesture_state;

// Gesture context structure
typedef struct {
	gesture_state state;
	swipe_axis axis;
	float start_x, start_y;      // average position at gesture start (axis-lock reference)
	float acc_dx;                // accumulated horizontal displacement this gesture
	float peak_velx;             // fastest horizontal velocity seen this gesture
	int executed_step;           // workspace switches actually performed this gesture (signed)
	float prev_x[MAX_TOUCHES];   // per-slot x position last frame, for delta computation
	bool dispatch_in_flight;     // at most one switch-dispatch outstanding
	char* cached_workspace_list; // aerospace_list_workspaces() result, reused for this gesture
} gesture_ctx;
```

- [ ] **Step 4: Add the workspace-dispatch queue and change `switch_workspace`'s signature**

In `src/main.m`, find (as left by Task 2):

```c
// Frames are dispatched here in delivery order, one at a time — required
// since gesture processing sums displacement across frames and a
// concurrent queue does not guarantee FIFO delivery under contention.
static dispatch_queue_t g_gesture_queue;
```

Replace it with:

```c
// Frames are dispatched here in delivery order, one at a time — required
// since gesture processing sums displacement across frames and a
// concurrent queue does not guarantee FIFO delivery under contention.
static dispatch_queue_t g_gesture_queue;

// Dedicated to blocking workspace-switch socket I/O, kept separate from
// g_gesture_queue so I/O never delays frame processing. At most one unit
// of work is ever outstanding here — see maybe_dispatch_switch().
static dispatch_queue_t g_workspace_queue;
```

In `src/main.m`, find (as left by Task 2):

```c
		g_gesture_queue = dispatch_queue_create("aerospace-swipe.gesture", DISPATCH_QUEUE_SERIAL);

		event_tap_begin(&g_event_tap, key_handler);
```

Replace it with:

```c
		g_gesture_queue = dispatch_queue_create("aerospace-swipe.gesture", DISPATCH_QUEUE_SERIAL);
		g_workspace_queue = dispatch_queue_create("aerospace-swipe.workspace", DISPATCH_QUEUE_SERIAL);

		event_tap_begin(&g_event_tap, key_handler);
```

In `src/main.m`, find `switch_workspace`:

```c
static void switch_workspace(const char* ws)
{
	pthread_mutex_lock(&g_aerospace_mutex);

	if (g_config.skip_empty || g_config.wrap_around) {
		char* workspaces = aerospace_list_workspaces(g_aerospace, !g_config.skip_empty);
		if (!workspaces) {
			fprintf(stderr, "Error: Unable to retrieve workspace list.\n");
			pthread_mutex_unlock(&g_aerospace_mutex);
			return;
		}
		char* result = aerospace_workspace(g_aerospace, g_config.wrap_around, ws, workspaces);
		if (result) {
			fprintf(stderr, "Error: Failed to switch workspace to '%s'.\n", ws);
		} else {
			printf("Switched workspace successfully to '%s'.\n", ws);
		}
		free(workspaces);
		free(result);
	} else {
		char* result = aerospace_switch(g_aerospace, ws);
		if (result) {
			fprintf(stderr, "Error: Failed to switch workspace: '%s'\n", result);
		} else {
			printf("Switched workspace successfully to '%s'.\n", ws);
		}
		free(result);
	}

	if (g_config.haptic && g_haptic)
		haptic_actuate(g_haptic, 3);

	pthread_mutex_unlock(&g_aerospace_mutex);
}
```

Replace it with:

```c
// cached_workspaces lets a caller reuse one aerospace_list_workspaces()
// snapshot across multiple calls within the same continuous gesture
// (window-to-workspace assignment doesn't change from focus-switching
// alone, so a stale-by-milliseconds cache is still correct). Pass a
// pointer to a caller-owned char* that starts NULL; this function fetches
// once and fills it in, and reuses it on subsequent calls.
static void switch_workspace(const char* ws, char** cached_workspaces)
{
	pthread_mutex_lock(&g_aerospace_mutex);

	if (g_config.skip_empty || g_config.wrap_around) {
		char* workspaces = cached_workspaces ? *cached_workspaces : NULL;
		if (!workspaces) {
			workspaces = aerospace_list_workspaces(g_aerospace, !g_config.skip_empty);
			if (!workspaces) {
				fprintf(stderr, "Error: Unable to retrieve workspace list.\n");
				pthread_mutex_unlock(&g_aerospace_mutex);
				return;
			}
			if (cached_workspaces)
				*cached_workspaces = workspaces;
		}
		char* result = aerospace_workspace(g_aerospace, g_config.wrap_around, ws, workspaces);
		if (result) {
			fprintf(stderr, "Error: Failed to switch workspace to '%s'.\n", ws);
		} else {
			printf("Switched workspace successfully to '%s'.\n", ws);
		}
		if (!cached_workspaces)
			free(workspaces);
		free(result);
	} else {
		char* result = aerospace_switch(g_aerospace, ws);
		if (result) {
			fprintf(stderr, "Error: Failed to switch workspace: '%s'\n", result);
		} else {
			printf("Switched workspace successfully to '%s'.\n", ws);
		}
		free(result);
	}

	if (g_config.haptic && g_haptic)
		haptic_actuate(g_haptic, 3);

	pthread_mutex_unlock(&g_aerospace_mutex);
}
```

- [ ] **Step 5: Replace `reset_gesture_state`/`fire_gesture` with the new firing functions**

In `src/main.m`, find:

```c
static void reset_gesture_state(gesture_ctx* ctx)
{
	ctx->state = GS_IDLE;
	ctx->last_fire_dir = 0;
}

static void fire_gesture(gesture_ctx* ctx, int direction)
{
	if (direction == ctx->last_fire_dir)
		return;

	ctx->last_fire_dir = direction;
	ctx->state = GS_COMMITTED;

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		switch_workspace(direction > 0 ? g_config.swipe_right : g_config.swipe_left);
	});
}
```

Replace it with:

```c
static void reset_gesture_state(gesture_ctx* ctx)
{
	ctx->state = GS_IDLE;
	ctx->axis = AXIS_UNDECIDED;
	ctx->acc_dx = 0;
	ctx->peak_velx = 0;
	ctx->executed_step = 0;

	// cached_workspace_list is also read/written under g_aerospace_mutex by
	// switch_workspace() from the workspace-dispatch queue; take the same
	// lock here so a still-in-flight dispatch never sees the pointer freed
	// out from under it. switch_workspace() always NULL-checks before use,
	// so whichever side wins the race, behavior stays correct — the only
	// possible cost is one redundant re-fetch of the workspace list.
	pthread_mutex_lock(&g_aerospace_mutex);
	free(ctx->cached_workspace_list);
	ctx->cached_workspace_list = NULL;
	pthread_mutex_unlock(&g_aerospace_mutex);
}

// At most one dispatch is ever outstanding: if one is already converging
// toward the target, this is a no-op — that dispatch re-reads the target
// fresh on every iteration, so it will pick up any further change without
// a second dispatch being scheduled. This bounds the backlog under rapid
// swiping without ever silently dropping a step (workspace next/prev are
// relative commands — a dropped step is a permanently wrong landing spot).
static void maybe_dispatch_switch(gesture_ctx* ctx)
{
	if (ctx->dispatch_in_flight)
		return;
	ctx->dispatch_in_flight = true;

	dispatch_async(g_workspace_queue, ^{
		for (;;) {
			pthread_mutex_lock(&g_gesture_mutex);
			int target = compute_target_step(ctx->acc_dx, g_config.distance_pct, g_config.max_steps);
			int delta = target - ctx->executed_step;
			pthread_mutex_unlock(&g_gesture_mutex);

			if (delta == 0)
				break;

			int step_dir = delta > 0 ? 1 : -1;
			switch_workspace(step_dir > 0 ? g_config.swipe_right : g_config.swipe_left,
				&ctx->cached_workspace_list);

			pthread_mutex_lock(&g_gesture_mutex);
			ctx->executed_step += step_dir;
			pthread_mutex_unlock(&g_gesture_mutex);
		}

		pthread_mutex_lock(&g_gesture_mutex);
		ctx->dispatch_in_flight = false;
		pthread_mutex_unlock(&g_gesture_mutex);
	});
}

// multi_swipe == false path: fire exactly one step, only at gesture
// release (called from gestureCallback when count == 0). Mirrors
// SwipeAeroSpace's own single-swipe fallback — no live mid-gesture
// feedback in this mode.
static void fire_single_swipe(gesture_ctx* ctx)
{
	bool fast = fabsf(ctx->peak_velx) >= g_config.fast_velocity_threshold;
	float need = fast ? g_config.distance_pct * g_config.fast_distance_factor : g_config.distance_pct;

	if (fabsf(ctx->acc_dx) < need)
		return;

	int step_dir = ctx->acc_dx > 0 ? 1 : -1;
	const char* ws = step_dir > 0 ? g_config.swipe_right : g_config.swipe_left;
	char** cache = &ctx->cached_workspace_list;

	dispatch_async(g_workspace_queue, ^{
		switch_workspace(ws, cache);
	});
}
```

- [ ] **Step 6: Replace `handle_committed_state`/`handle_idle_state`/`handle_armed_state`**

In `src/main.m`, find `handle_committed_state`, `handle_idle_state`, and
`handle_armed_state` in full (`calculate_touch_averages`, immediately
above this block, is unchanged and stays exactly as-is — do not touch it):

```c
static bool handle_committed_state(gesture_ctx* ctx, touch* touches, int count)
{
	bool all_ended = true;
	for (int i = 0; i < count; ++i) {
		if (touches[i].phase != END_PHASE) {
			all_ended = false;
			break;
		}
	}

	if (!count || all_ended) {
		reset_gesture_state(ctx);
		return true;
	}

	float avg_x, avg_y, avg_vel, min_x, max_x, min_y, max_y;
	calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_vel,
		&min_x, &max_x, &min_y, &max_y);

	float dx = avg_x - ctx->start_x;
	if ((dx * ctx->last_fire_dir) < 0 && fabsf(dx) >= g_config.min_travel) {
		ctx->state = GS_ARMED;
		ctx->start_x = avg_x;
		ctx->start_y = avg_y;
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;

		for (int i = 0; i < count; ++i) {
			if (touches[i].slot < 0)
				continue;
			ctx->base_x[touches[i].slot] = touches[i].x;
		}
	}

	return true;
}

static void handle_idle_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_vel)
{
	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float need = fast ? g_config.min_travel_fast : g_config.min_travel;

	// Count how many fingers have moved enough (allow some to lag)
	int moved_count = 0;
	for (int i = 0; i < count; ++i) {
		if (touches[i].slot < 0)
			continue;
		if (fabsf(touches[i].x - ctx->base_x[touches[i].slot]) >= need)
			moved_count++;
	}
	// At least half the fingers should have moved
	bool moved = (moved_count >= (count + 1) / 2);

	float dx = avg_x - ctx->start_x;
	float dy = avg_y - ctx->start_y;

	// Arm if moved and horizontal movement dominates
	if (moved && (fast || fabsf(dx) >= ACTIVATE_PCT || fabsf(avg_vel) >= g_config.velocity_pct * 0.5f)) {
		// Horizontal must be greater than vertical (original behavior)
		if (fabsf(dx) > fabsf(dy) || fast) {
			ctx->state = GS_ARMED;
			ctx->start_x = avg_x;
			ctx->start_y = avg_y;
			ctx->peak_velx = avg_vel;
			ctx->dir = (avg_vel >= 0) ? 1 : -1;
		}
	}
}

static void handle_armed_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_vel)
{
	float dx = avg_x - ctx->start_x;
	float dy = avg_y - ctx->start_y;

	// Reset if vertical movement exceeds horizontal (with small tolerance for diagonal)
	if (fabsf(dy) > fabsf(dx) * 1.2f) {
		reset_gesture_state(ctx);
		return;
	}

	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float stepReq = fast ? g_config.min_step_fast : g_config.min_step;

	int mismatch_count = 0;
	for (int i = 0; i < count; ++i) {
		if (touches[i].slot < 0)
			continue;
		float ddx = touches[i].x - ctx->prev_x[touches[i].slot];
		if (fabsf(ddx) < stepReq || (ddx * dx) < 0) {
			mismatch_count++;
			if (mismatch_count > g_config.swipe_tolerance) {
				reset_gesture_state(ctx);
				return;
			}
		}
	}

	if (fabsf(avg_vel) > fabsf(ctx->peak_velx)) {
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;
	}

	// Fire based on distance
	if (fabsf(dx) >= g_config.distance_pct) {
		fire_gesture(ctx, dx > 0 ? 1 : -1);
	}
	// Or fire on fast intentional swipes (for medium/high sensitivity)
	// Must reach at least fast_distance_factor of the threshold distance
	else if (fabsf(avg_vel) >= g_config.fast_velocity_threshold &&
	         fabsf(dx) >= g_config.distance_pct * g_config.fast_distance_factor) {
		fire_gesture(ctx, dx > 0 ? 1 : -1);
	}
}
```

Replace the whole three-function block with:

```c
static void handle_idle_state(gesture_ctx* ctx, touch* touches, int count, float avg_x, float avg_y)
{
	ctx->state = GS_TRACKING;
	ctx->axis = AXIS_UNDECIDED;
	ctx->acc_dx = 0;
	ctx->peak_velx = 0;
	ctx->executed_step = 0;
	ctx->start_x = avg_x;
	ctx->start_y = avg_y;

	for (int i = 0; i < count; ++i) {
		if (touches[i].slot < 0)
			continue;
		ctx->prev_x[touches[i].slot] = touches[i].x;
	}
}

static void handle_tracking_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_vel)
{
	float frame_dx = 0;
	int moved = 0;
	for (int i = 0; i < count; ++i) {
		if (touches[i].slot < 0)
			continue;
		frame_dx += touches[i].x - ctx->prev_x[touches[i].slot];
		ctx->prev_x[touches[i].slot] = touches[i].x;
		moved++;
	}
	if (moved > 0)
		ctx->acc_dx += frame_dx / moved;

	if (fabsf(avg_vel) > fabsf(ctx->peak_velx))
		ctx->peak_velx = avg_vel;

	if (ctx->axis == AXIS_UNDECIDED)
		ctx->axis = decide_axis(avg_x - ctx->start_x, avg_y - ctx->start_y, ACTIVATE_PCT);

	if (ctx->axis != AXIS_HORIZONTAL || !g_config.multi_swipe)
		return;

	int target = compute_target_step(ctx->acc_dx, g_config.distance_pct, g_config.max_steps);
	if (target != ctx->executed_step)
		maybe_dispatch_switch(ctx);
}
```

Note what this intentionally drops relative to the old `handle_idle_state`:
the old code required a minimum fraction of fingers to move a minimum
distance from a `base_x` baseline before arming at all. The new model arms
(`GS_IDLE` → `GS_TRACKING`) the instant the finger count matches — actual
firing still requires `acc_dx` to cross `distance_pct` (a much larger
threshold), so resting 4 fingers without moving still can't fire. This
matches SwipeAeroSpace's own `state = .began` transition, which also just
requires the right finger count, not a pre-movement gate.

- [ ] **Step 7: Replace `gestureCallback`**

In `src/main.m`, find `gestureCallback`:

```c
static void gestureCallback(touch* touches, int count)
{
	if (!g_enabled)
		return;

	pthread_mutex_lock(&g_gesture_mutex);

	gesture_ctx* ctx = &g_gesture_ctx;

	if (ctx->state == GS_COMMITTED) {
		if (handle_committed_state(ctx, touches, count))
			goto unlock;
	}

	if (count != g_config.fingers) {
		if (ctx->state == GS_ARMED) {
			ctx->miscount_frames++;
			if (ctx->miscount_frames > MISCOUNT_GRACE_FRAMES) {
				ctx->state = GS_IDLE;
				ctx->miscount_frames = 0;
			} else {
				// Tolerate a brief miscount frame: skip updating history
				// this frame instead of resetting armed progress, so a
				// finger landing a beat late or a fifth incidental touch
				// doesn't throw away a real in-progress swipe.
				goto unlock;
			}
		}

		for (int i = 0; i < count; ++i) {
			if (touches[i].slot < 0)
				continue;
			ctx->prev_x[touches[i].slot] = ctx->base_x[touches[i].slot] = touches[i].x;
		}

		goto unlock;
	}

	ctx->miscount_frames = 0;

	float avg_x, avg_y, avg_vel, min_x, max_x, min_y, max_y;
	calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_vel,
		&min_x, &max_x, &min_y, &max_y);

	if (ctx->state == GS_IDLE) {
		handle_idle_state(ctx, touches, count, avg_x, avg_y, avg_vel);
	} else if (ctx->state == GS_ARMED) {
		handle_armed_state(ctx, touches, count, avg_x, avg_y, avg_vel);
	}

	for (int i = 0; i < count; ++i) {
		if (touches[i].slot < 0)
			continue;
		ctx->prev_x[touches[i].slot] = touches[i].x;
		if (ctx->state == GS_IDLE)
			ctx->base_x[touches[i].slot] = touches[i].x;
	}

unlock:
	pthread_mutex_unlock(&g_gesture_mutex);
}
```

Replace it with:

```c
static void gestureCallback(touch* touches, int count)
{
	if (!g_enabled)
		return;

	pthread_mutex_lock(&g_gesture_mutex);

	gesture_ctx* ctx = &g_gesture_ctx;

	if (count == 0) {
		if (ctx->state == GS_TRACKING && !g_config.multi_swipe
			&& ctx->axis == AXIS_HORIZONTAL)
			fire_single_swipe(ctx);
		reset_gesture_state(ctx);
		goto unlock;
	}

	if (ctx->state == GS_IDLE) {
		if (count != g_config.fingers) {
			for (int i = 0; i < count; ++i) {
				if (touches[i].slot < 0)
					continue;
				ctx->prev_x[touches[i].slot] = touches[i].x;
			}
			goto unlock;
		}

		float avg_x, avg_y, avg_vel, min_x, max_x, min_y, max_y;
		calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_vel,
			&min_x, &max_x, &min_y, &max_y);
		handle_idle_state(ctx, touches, count, avg_x, avg_y);
		goto unlock;
	}

	// GS_TRACKING: tolerate finger-count drift (e.g. a transient miscount,
	// or an extra incidental contact) instead of resetting progress. Only
	// a true full release (count == 0, handled above) ends the gesture.
	{
		float avg_x, avg_y, avg_vel, min_x, max_x, min_y, max_y;
		calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_vel,
			&min_x, &max_x, &min_y, &max_y);
		handle_tracking_state(ctx, touches, count, avg_x, avg_y, avg_vel);
	}

unlock:
	pthread_mutex_unlock(&g_gesture_mutex);
}
```

- [ ] **Step 8: Build, then manually validate**

Run: `cd /Users/momeppkt/Developer/aerospace-swipe/.worktrees/gesture-touch-identity-tracking && make test && make clean && make all`
Expected: all three unit test binaries pass; the app builds with no
errors or warnings about unused `gesture_ctx`/`Config` fields.

Then rebuild and run `AerospaceSwipe` in the foreground (not as a service)
per this project's established manual-validation approach (re-grant
Accessibility if the ad-hoc signature changed, per this session's known
pattern), and check:

- Swipe the same direction 15+ times in a row, at a natural pace: every
  swipe should register — the original "locked" repro (works ~10 times,
  then stops, needs a pause or reversal to recover) must not reproduce.
- Swipe rapidly, repeatedly: workspace changes should keep pace with the
  physical swipes rather than visibly catching up afterward.
- A single continuous swipe covering more than one workspace's worth of
  distance should switch multiple workspaces live, capped at
  `max_steps` (5 by default).
- Set `"multi_swipe": false` in `~/.config/aerospace-swipe/config.json`,
  restart, and confirm: one switch per gesture, firing only on release,
  no mid-gesture feedback.
- An accidental vertical (e.g. Mission-Control-style) 4-finger swipe
  should still be correctly ignored for workspace switching.
- A diagonal correction partway through an in-progress horizontal swipe
  should not cancel it (axis locks once, at the start of the gesture, not
  re-evaluated every frame).

- [ ] **Step 9: Commit**

```bash
git add src/event_tap.h src/config.h src/main.m
git commit -m "feat: replace lock-on-fire gesture state machine with continuous multi-step firing"
```

---

## Post-plan note

This plan does not include Task 5 from the prior plan (release v1.0.1,
bump the Homebrew formula's stable `tag:`/`revision:`) — that remains
pending and should happen once this plan's changes are validated and
merged, covering both plans' work in one release.
