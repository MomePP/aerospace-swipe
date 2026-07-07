# Stable Per-Finger Touch Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 4-finger swipes silently failing to register by tracking each finger's history by its stable `NSTouch.identity` instead of its position in a per-frame `NSSet` (whose enumeration order is not guaranteed stable across callbacks), and by tolerating a single noisy finger-count frame instead of immediately discarding armed gesture progress.

**Architecture:** A new pure-C slot allocator in `src/event_tap.m`/`src/event_tap.h` maps each `NSTouch.identity` to a stable integer slot (`[0, MAX_TOUCHES)`), assigned on first contact and freed on lift. `TouchConverter convert_nstouch:` populates a new `touch.slot` field from this allocator. `src/main.m`'s gesture state machine (`gestureCallback`, `handle_idle_state`, `handle_armed_state`, `handle_committed_state`) is changed to index `gesture_ctx.prev_x`/`base_x` by `touches[i].slot` instead of the raw loop index `i`. Separately, `gestureCallback` gets a small grace counter so a single frame with the wrong touch count doesn't immediately drop `GS_ARMED` back to `GS_IDLE`.

**Tech Stack:** C99 + Objective-C, Core Foundation (`CFDictionary`), AppKit (`NSTouch`), existing `clang`/`make` toolchain — no new dependencies.

## Global Constraints

- No new user-facing config options (spec: "Non-goals").
- Preserve existing config knobs and their current meaning/defaults — `sensitivity`, `swipe_tolerance`, `min_travel`, etc. are unchanged; this is a correctness fix to the data those knobs operate on, not a retuning (spec: "Goals").
- No changes to AeroSpace-side wrap-around/skip-empty behavior — already verified correct in isolation (spec: "Root cause").
- No changes to `apply_sensitivity` preset values in `config.h` (spec: "Non-goals").
- No automated test harness exists for the live touch/gesture pipeline (it depends on real `NSTouch`/`CGEventTap` input) — validation of the gesture-detection change itself is manual/empirical, done by the user with a real trackpad (spec: "Testing / validation"). The one piece of *new* logic that is pure and side-effect-free (the slot allocator) gets real automated unit tests.

---

### Task 1: Per-finger slot allocator + unit test

**Files:**
- Modify: `src/event_tap.h`
- Modify: `src/event_tap.m`
- Create: `test/test_touch_slots.m`
- Modify: `makefile`

**Interfaces:**
- Produces: `int touch_slot_acquire(const void* identity)` — returns an existing or newly-assigned slot in `[0, MAX_TOUCHES)` for `identity`, or `-1` if all `MAX_TOUCHES` slots are currently in use. Calling it again with the same `identity` before releasing returns the same slot.
- Produces: `void touch_slot_release(const void* identity)` — frees the slot associated with `identity` so it can be reused by a later identity. Safe no-op if `identity` was never acquired or was already released.
- Consumes: `MAX_TOUCHES` (already defined in `src/event_tap.h`, value `16`).

- [ ] **Step 1: Add the function declarations to `src/event_tap.h`**

In `src/event_tap.h`, add the two declarations right after the existing `extern` declarations near the top (after line 15, `extern char* string_copy(char* s);`):

```c
extern const char* get_name_for_pid(uint64_t pid);
extern char* string_copy(char* s);

// Maps an NSTouch.identity to a stable per-finger slot in [0, MAX_TOUCHES).
// Unlike NSSet enumeration order (which is not guaranteed stable across
// separate gesture callbacks), the returned slot is stable for the whole
// lifetime of one physical finger's contact — acquiring the same identity
// twice returns the same slot until it's released.
int touch_slot_acquire(const void* identity);
void touch_slot_release(const void* identity);
```

- [ ] **Step 2: Implement the allocator in `src/event_tap.m`**

In `src/event_tap.m`, add the implementation right after `struct event_tap g_event_tap = { 0 };` (line 9) and before `@implementation TouchConverter` (line 11):

```c
struct event_tap g_event_tap = { 0 };

// identity -> (slot + 1), so 0 unambiguously means "not present" in the
// CFDictionary lookup below. Values are stuffed directly into the
// pointer-sized slot (no malloc) since kCFTypeDictionaryKeyCallBacks only
// needs real retain/release semantics for the *keys* (the NSTouch identity
// objects), not these plain integers.
static CFMutableDictionaryRef g_touch_slots = NULL;
static bool g_slot_in_use[MAX_TOUCHES] = { false };

int touch_slot_acquire(const void* identity)
{
	if (!g_touch_slots) {
		g_touch_slots = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);
	}

	const void* existing = CFDictionaryGetValue(g_touch_slots, identity);
	if (existing) {
		return (int)(intptr_t)existing - 1;
	}

	for (int slot = 0; slot < MAX_TOUCHES; ++slot) {
		if (!g_slot_in_use[slot]) {
			g_slot_in_use[slot] = true;
			CFDictionarySetValue(g_touch_slots, identity, (const void*)(intptr_t)(slot + 1));
			return slot;
		}
	}

	return -1;
}

void touch_slot_release(const void* identity)
{
	if (!g_touch_slots)
		return;

	const void* existing = CFDictionaryGetValue(g_touch_slots, identity);
	if (!existing)
		return;

	int slot = (int)(intptr_t)existing - 1;
	if (slot >= 0 && slot < MAX_TOUCHES)
		g_slot_in_use[slot] = false;

	CFDictionaryRemoveValue(g_touch_slots, identity);
}

@implementation TouchConverter
```

`src/event_tap.m` already includes `<CoreFoundation/CoreFoundation.h>` (line 3), which declares `CFDictionaryCreateMutable`/`CFDictionaryGetValue`/`CFDictionarySetValue`/`CFDictionaryRemoveValue`, so no new `#include` is needed. `intptr_t` needs `<stdint.h>`, which `event_tap.h` already includes (line 7) and `event_tap.m` includes transitively via `#import "event_tap.h"` (line 1).

- [ ] **Step 3: Write the unit test**

Create `test/test_touch_slots.m`:

```objc
// Standalone unit test for the per-finger slot allocator in event_tap.m.
// Builds independently of the full app (no CGEventTap, no NSApplication) so
// it runs without Accessibility permission or a live trackpad. Run via
// `make test`.
#import <Foundation/Foundation.h>
#import <assert.h>
#import "../src/event_tap.h"

int main(void)
{
	@autoreleasepool {
		NSObject* fingerA = [NSObject new];
		NSObject* fingerB = [NSObject new];
		NSObject* fingerC = [NSObject new];

		int slotA = touch_slot_acquire((__bridge const void*)fingerA);
		assert(slotA >= 0 && slotA < MAX_TOUCHES);

		// Acquiring again for the SAME identity returns the SAME slot —
		// this is what keeps prev_x[slot]/base_x[slot] stable across
		// frames even though NSSet enumeration order is not.
		int slotAAgain = touch_slot_acquire((__bridge const void*)fingerA);
		assert(slotAAgain == slotA);

		// A different identity gets a different slot.
		int slotB = touch_slot_acquire((__bridge const void*)fingerB);
		assert(slotB >= 0 && slotB < MAX_TOUCHES);
		assert(slotB != slotA);

		// Releasing a slot frees it for reuse by a later identity.
		touch_slot_release((__bridge const void*)fingerA);
		int slotC = touch_slot_acquire((__bridge const void*)fingerC);
		assert(slotC == slotA);

		// Releasing an identity that was never acquired is a safe no-op.
		NSObject* neverAcquired = [NSObject new];
		touch_slot_release((__bridge const void*)neverAcquired);

		// Releasing the same identity twice is a safe no-op the second time.
		touch_slot_release((__bridge const void*)fingerB);
		touch_slot_release((__bridge const void*)fingerB);

		// Only slotC (reused from A) remains in use; MAX_TOUCHES - 1 slots
		// are free. Fill them all, then confirm the next acquire reports
		// exhaustion (-1) instead of corrupting state or crashing.
		NSMutableArray* fillers = [NSMutableArray array];
		for (int i = 0; i < MAX_TOUCHES - 1; ++i) {
			NSObject* filler = [NSObject new];
			[fillers addObject:filler];
			int slot = touch_slot_acquire((__bridge const void*)filler);
			assert(slot >= 0 && slot < MAX_TOUCHES);
		}

		NSObject* oneTooMany = [NSObject new];
		int overflowSlot = touch_slot_acquire((__bridge const void*)oneTooMany);
		assert(overflowSlot == -1);
	}

	printf("test_touch_slots: all assertions passed\n");
	return 0;
}
```

- [ ] **Step 4: Add a `test` target to the `makefile`**

In `makefile`, change the `.PHONY` line (currently `.PHONY: all clean sign install_plist load_plist uninstall_plist install uninstall`) to include `test`:

```makefile
.PHONY: all clean sign install_plist load_plist uninstall_plist install uninstall test
```

Then add the target itself, right after the `$(TARGET): $(SRC_FILES)` rule (after the line `$(CC) $(CFLAGS) $(ARCH) -o $(TARGET) $(SRC_FILES) $(FRAMEWORKS) $(LDLIBS)`):

```makefile
TEST_TARGET = test_touch_slots

test: $(TEST_TARGET)
	./$(TEST_TARGET)

$(TEST_TARGET): src/event_tap.m test/test_touch_slots.m
	$(CC) $(CFLAGS) $(ARCH) -o $(TEST_TARGET) src/event_tap.m test/test_touch_slots.m $(FRAMEWORKS) $(LDLIBS)
```

Also add `$(TEST_TARGET)` to the existing `clean` target so `make clean` removes it too. Current `clean` target:

```makefile
clean:
	rm -rf $(TARGET) $(APP_BUNDLE)
```

New:

```makefile
clean:
	rm -rf $(TARGET) $(APP_BUNDLE) $(TEST_TARGET)
```

- [ ] **Step 5: Run the test to verify it fails to build (function not yet declared/linked correctly is not the concern here — verify it builds and passes, since this is new code, not a red/green TDD cycle against pre-existing behavior)**

Run: `cd /Users/momeppkt/.local/share/aerospace-swipe && make test`

Expected: compiles cleanly and prints:
```
test_touch_slots: all assertions passed
```

If it fails to compile, the most likely cause is a missing `#import` — double check `test/test_touch_slots.m` has both `#import <Foundation/Foundation.h>` and `#import "../src/event_tap.h"`.

- [ ] **Step 6: Commit**

```bash
cd /Users/momeppkt/.local/share/aerospace-swipe
git add src/event_tap.h src/event_tap.m test/test_touch_slots.m makefile
git commit -m "feat: add stable per-finger touch slot allocator"
```

---

### Task 2: Wire the slot allocator into `TouchConverter`

**Files:**
- Modify: `src/event_tap.h`
- Modify: `src/event_tap.m`

**Interfaces:**
- Consumes: `int touch_slot_acquire(const void* identity)`, `void touch_slot_release(const void* identity)` (Task 1).
- Produces: `touch.slot` (new field, populated on every `touch` returned by `TouchConverter convert_nstouch:`) — consumed by Task 3.

- [ ] **Step 1: Add the `slot` field to the `touch` struct**

In `src/event_tap.h`, the current `touch` struct (lines 23–30):

```c
typedef struct {
	double x;
	double y;
	int phase;
	double timestamp;
	double velocity;
	bool is_palm;
} touch;
```

Change to:

```c
typedef struct {
	double x;
	double y;
	int phase;
	double timestamp;
	double velocity;
	bool is_palm;
	int slot; // stable per-finger index from touch_slot_acquire(), or -1
} touch;
```

- [ ] **Step 2: Populate `nt.slot` in `convert_nstouch:`**

In `src/event_tap.m`, the current `convert_nstouch:` body:

```objc
+ (touch)convert_nstouch:(id)nsTouch
{
	NSTouch* touchObj = (NSTouch*)nsTouch;
	touch nt;

	CGPoint pos = [touchObj normalizedPosition];
	nt.x = pos.x;
	nt.y = pos.y;

	nt.phase = (int)[touchObj phase];
	nt.timestamp = [[touchObj valueForKey:@"timestamp"] doubleValue];

	id touchIdentity = [touchObj identity];

	if (!touchStates) {
		touchStates = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);
	}

	double velocity_x = 0.0;
	touch_state* state = (touch_state*)CFDictionaryGetValue(touchStates, (__bridge const void*)(touchIdentity));
	if (state) {
		double dt = nt.timestamp - state->timestamp;
		if (dt > 0)
			velocity_x = (nt.x - state->x) / dt;
		state->x = nt.x;
		state->y = nt.y;
		state->timestamp = nt.timestamp;
	} else {
		state = malloc(sizeof(touch_state));
		if (state) {
			state->x = nt.x;
			state->y = nt.y;
			state->timestamp = nt.timestamp;
			CFDictionarySetValue(touchStates, (__bridge const void*)(touchIdentity), state);
		}
	}
	nt.velocity = velocity_x;

	if (nt.phase == 8) {
		CFDictionaryRemoveValue(touchStates, (__bridge const void*)(touchIdentity));
		if (state)
			free(state);
	}

	return nt;
}
```

Change to (two additions: acquiring the slot right after `touchIdentity` is computed, and releasing it in the existing end-phase block):

```objc
+ (touch)convert_nstouch:(id)nsTouch
{
	NSTouch* touchObj = (NSTouch*)nsTouch;
	touch nt;

	CGPoint pos = [touchObj normalizedPosition];
	nt.x = pos.x;
	nt.y = pos.y;

	nt.phase = (int)[touchObj phase];
	nt.timestamp = [[touchObj valueForKey:@"timestamp"] doubleValue];

	id touchIdentity = [touchObj identity];
	nt.slot = touch_slot_acquire((__bridge const void*)(touchIdentity));

	if (!touchStates) {
		touchStates = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);
	}

	double velocity_x = 0.0;
	touch_state* state = (touch_state*)CFDictionaryGetValue(touchStates, (__bridge const void*)(touchIdentity));
	if (state) {
		double dt = nt.timestamp - state->timestamp;
		if (dt > 0)
			velocity_x = (nt.x - state->x) / dt;
		state->x = nt.x;
		state->y = nt.y;
		state->timestamp = nt.timestamp;
	} else {
		state = malloc(sizeof(touch_state));
		if (state) {
			state->x = nt.x;
			state->y = nt.y;
			state->timestamp = nt.timestamp;
			CFDictionarySetValue(touchStates, (__bridge const void*)(touchIdentity), state);
		}
	}
	nt.velocity = velocity_x;

	if (nt.phase == 8) {
		CFDictionaryRemoveValue(touchStates, (__bridge const void*)(touchIdentity));
		if (state)
			free(state);
		touch_slot_release((__bridge const void*)(touchIdentity));
	}

	return nt;
}
```

- [ ] **Step 3: Rebuild and confirm no compile errors or new warnings**

Run: `cd /Users/momeppkt/.local/share/aerospace-swipe && make clean && make all`

Expected: builds successfully. The only warnings should be the two pre-existing ones already present before this change (`comparison of different enumeration types` in `main.m` around the `NSEventTypeGesture` check, and the two `unused parameter 'argc'/'argv'` warnings in `main()`) — no *new* warnings about `slot` being uninitialized or unused.

- [ ] **Step 4: Re-run the Task 1 unit test to confirm nothing broke**

Run: `make test`

Expected: still prints `test_touch_slots: all assertions passed` (this task didn't touch the allocator itself, just its caller, so this is a regression check).

- [ ] **Step 5: Commit**

```bash
cd /Users/momeppkt/.local/share/aerospace-swipe
git add src/event_tap.h src/event_tap.m
git commit -m "feat: populate touch.slot from the per-finger slot allocator"
```

---

### Task 3: Index gesture history by slot instead of array position

**Files:**
- Modify: `src/main.m`

**Interfaces:**
- Consumes: `touch.slot` (Task 2), `MAX_TOUCHES` (`src/event_tap.h`).

This is the core fix: every place that currently reads/writes `ctx->prev_x[i]` or `ctx->base_x[i]` (where `i` is the raw loop index into this frame's touch array) instead uses `ctx->prev_x[touches[i].slot]` / `ctx->base_x[touches[i].slot]`. A defensive `slot < 0` guard (the allocator's exhaustion case from Task 1) skips using that touch for indexed history without crashing — `MAX_TOUCHES` is 16 and real trackpads report at most ~11 simultaneous contacts, so this should not trigger in practice, but indexing `prev_x[-1]` would be undefined behavior if it ever did.

- [ ] **Step 1: Update `handle_committed_state`**

Current (`src/main.m`, inside `handle_committed_state`):

```c
	float dx = avg_x - ctx->start_x;
	if ((dx * ctx->last_fire_dir) < 0 && fabsf(dx) >= g_config.min_travel) {
		ctx->state = GS_ARMED;
		ctx->start_x = avg_x;
		ctx->start_y = avg_y;
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;

		for (int i = 0; i < count; ++i)
			ctx->base_x[i] = touches[i].x;
	}

	return true;
}
```

Change to:

```c
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
```

- [ ] **Step 2: Update `handle_idle_state`**

Current:

```c
static void handle_idle_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_vel)
{
	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float need = fast ? g_config.min_travel_fast : g_config.min_travel;

	// Count how many fingers have moved enough (allow some to lag)
	int moved_count = 0;
	for (int i = 0; i < count; ++i) {
		if (fabsf(touches[i].x - ctx->base_x[i]) >= need)
			moved_count++;
	}
	// At least half the fingers should have moved
	bool moved = (moved_count >= (count + 1) / 2);
```

Change the loop to:

```c
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
```

(The rest of `handle_idle_state` is unchanged.)

- [ ] **Step 3: Update `handle_armed_state`**

Current:

```c
	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float stepReq = fast ? g_config.min_step_fast : g_config.min_step;

	int mismatch_count = 0;
	for (int i = 0; i < count; ++i) {
		float ddx = touches[i].x - ctx->prev_x[i];
		if (fabsf(ddx) < stepReq || (ddx * dx) < 0) {
			mismatch_count++;
			if (mismatch_count > g_config.swipe_tolerance) {
				reset_gesture_state(ctx);
				return;
			}
		}
	}
```

Change to:

```c
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
```

(The rest of `handle_armed_state` is unchanged.)

- [ ] **Step 4: Update `gestureCallback`'s two touch-array loops**

Current (`src/main.m`, inside `gestureCallback`):

```c
	if (count != g_config.fingers) {
		if (ctx->state == GS_ARMED)
			ctx->state = GS_IDLE;

		for (int i = 0; i < count; ++i)
			ctx->prev_x[i] = ctx->base_x[i] = touches[i].x;

		goto unlock;
	}
```

Change to:

```c
	if (count != g_config.fingers) {
		if (ctx->state == GS_ARMED)
			ctx->state = GS_IDLE;

		for (int i = 0; i < count; ++i) {
			if (touches[i].slot < 0)
				continue;
			ctx->prev_x[touches[i].slot] = ctx->base_x[touches[i].slot] = touches[i].x;
		}

		goto unlock;
	}
```

And further down in the same function, current:

```c
	for (int i = 0; i < count; ++i) {
		ctx->prev_x[i] = touches[i].x;
		if (ctx->state == GS_IDLE)
			ctx->base_x[i] = touches[i].x;
	}

unlock:
	pthread_mutex_unlock(&g_gesture_mutex);
}
```

Change to:

```c
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

- [ ] **Step 5: Rebuild and confirm no compile errors or new warnings**

Run: `cd /Users/momeppkt/.local/share/aerospace-swipe && make clean && make all`

Expected: same as Task 2 Step 3 — builds successfully, no new warnings beyond the two pre-existing ones.

- [ ] **Step 6: Re-run the Task 1 unit test**

Run: `make test`

Expected: `test_touch_slots: all assertions passed` (this task didn't touch the allocator).

- [ ] **Step 7: Manual empirical validation — this is the real test for this task**

There is no automated way to simulate real multi-touch trackpad input (documented as a known gap in the design spec), so this step is a concrete manual procedure, not an automated check:

1. Stop the running service so the foreground build doesn't conflict with it:
   `brew services stop momepp/formulae/aerospace-swipe`
2. Run the freshly built binary in the foreground:
   `./swipe`
   (this is the bare binary from `make all`, not the `.app` bundle — it will prompt for Accessibility again the first time since it's a new build; grant it when prompted, same as every previous rebuild this session)
3. With the foreground process running and its stdout/stderr visible in the terminal, do at least 15 real 4-finger swipes (mix of left and right), leaving a couple of seconds between each.
4. Count how many of the 15 result in `Switched workspace successfully to '...'` printed vs. no output at all for that attempt.
5. Compare against the pre-fix baseline you already described ("hard to swipe... even at High sensitivity") — report back whether the hit rate is now noticeably better. If it's not, this task is not done — report the exact symptom (nothing at all vs. some fraction failing) so the diagnosis can be revisited before moving to Task 4.
6. Stop the foreground process (Ctrl-C) and restart the real service:
   `brew services start momepp/formulae/aerospace-swipe`

- [ ] **Step 8: Commit**

```bash
cd /Users/momeppkt/.local/share/aerospace-swipe
git add src/main.m
git commit -m "fix: index gesture per-finger history by stable slot, not array position"
```

---

### Task 4: Tolerant finger-count gate

**Files:**
- Modify: `src/event_tap.h`
- Modify: `src/main.m`

**Interfaces:**
- Consumes: `gesture_ctx` (extended with one new field).

- [ ] **Step 1: Add `miscount_frames` to `gesture_ctx`**

In `src/event_tap.h`, current:

```c
// Gesture context structure
typedef struct {
	gesture_state state;
	float start_x, start_y, peak_velx;
	int dir, last_fire_dir;
	float prev_x[MAX_TOUCHES], base_x[MAX_TOUCHES];
} gesture_ctx;
```

Change to:

```c
// Gesture context structure
typedef struct {
	gesture_state state;
	float start_x, start_y, peak_velx;
	int dir, last_fire_dir;
	float prev_x[MAX_TOUCHES], base_x[MAX_TOUCHES];
	int miscount_frames; // consecutive frames where touch count != g_config.fingers while GS_ARMED
} gesture_ctx;
```

- [ ] **Step 2: Add the grace-period constant**

In `src/event_tap.h`, add next to the other gesture-tuning macros (after `#define FAST_VEL_FACTOR 0.80f`, before `#define MAX_TOUCHES 16`):

```c
#define ACTIVATE_PCT 0.05f
#define END_PHASE 8 // NSTouchPhaseEnded
#define FAST_VEL_FACTOR 0.80f
#define MISCOUNT_GRACE_FRAMES 3 // consecutive wrong-count frames tolerated while armed before resetting
#define MAX_TOUCHES 16
```

- [ ] **Step 3: Use the grace counter in `gestureCallback`**

Current (`src/main.m`, the block from Task 3 Step 4 — shown here already updated with the Task 3 slot-indexing change):

```c
	if (count != g_config.fingers) {
		if (ctx->state == GS_ARMED)
			ctx->state = GS_IDLE;

		for (int i = 0; i < count; ++i) {
			if (touches[i].slot < 0)
				continue;
			ctx->prev_x[touches[i].slot] = ctx->base_x[touches[i].slot] = touches[i].x;
		}

		goto unlock;
	}
```

Change to:

```c
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
```

Note the added `ctx->miscount_frames = 0;` on its own line right after the closing `}` of the `if (count != g_config.fingers)` block (i.e. it runs whenever `count == g_config.fingers`, resetting the grace counter once the count is correct again — placed before the existing `float avg_x, avg_y, ...` declaration that already follows in this function).

- [ ] **Step 4: Rebuild and confirm no compile errors or new warnings**

Run: `cd /Users/momeppkt/.local/share/aerospace-swipe && make clean && make all`

Expected: builds successfully, same pre-existing warnings only.

- [ ] **Step 5: Re-run the Task 1 unit test**

Run: `make test`

Expected: `test_touch_slots: all assertions passed`.

- [ ] **Step 6: Manual empirical validation**

Repeat the same procedure as Task 3 Step 7 (stop service → run `./swipe` in foreground → 15 real 4-finger swipes → compare hit rate → restart service). This time, additionally test the specific scenario this task targets: try deliberately landing your 4 fingers slightly out of sync (stagger the touch-down by a few tens of milliseconds) — before this task, that's expected to have been an easy way to make a swipe fail; confirm it's now tolerated as long as all 4 fingers are down before you start actually swiping horizontally.

- [ ] **Step 7: Commit**

```bash
cd /Users/momeppkt/.local/share/aerospace-swipe
git add src/event_tap.h src/main.m
git commit -m "feat: tolerate brief finger-count misreads instead of resetting armed gesture"
```

---

### Task 5: Release v1.0.1 and update the stable Homebrew path

**Files:**
- Modify: `makefile`
- Modify: `aerospace-swipe.rb` (in the separately-cloned `MomePP/homebrew-formulae` tap repo)

**Interfaces:**
- Consumes: the `VERSION` variable already present in `makefile` (currently `1.0.0`), the existing `url ..., tag:, revision:` stable block already present in `aerospace-swipe.rb`.

- [ ] **Step 1: Bump the version**

In `makefile`, current:

```makefile
LDLIBS = -ldl
TARGET = swipe
VERSION = 1.0.0
```

Change to:

```makefile
LDLIBS = -ldl
TARGET = swipe
VERSION = 1.0.1
```

- [ ] **Step 2: Rebuild, confirm the version lands in the app bundle**

Run:
```bash
cd /Users/momeppkt/.local/share/aerospace-swipe
make clean && make bundle
plutil -p AerospaceSwipe.app/Contents/Info.plist | grep -i version
```

Expected output includes:
```
"CFBundleShortVersionString" => "1.0.1"
"CFBundleVersion" => "1.0.1"
```

Then clean up the local build artifact (it's not the install path — Homebrew rebuilds from source):
```bash
make clean
```

- [ ] **Step 3: Commit, tag, and push**

```bash
cd /Users/momeppkt/.local/share/aerospace-swipe
git add makefile
git commit -m "release: v1.0.1 — stable per-finger touch tracking"
git tag -a v1.0.1 -m "v1.0.1"
git push origin main
git push origin v1.0.1
git rev-parse v1.0.1^{commit}
```

Note the SHA printed by the last command — it's needed for Step 4.

- [ ] **Step 4: Update the Homebrew formula's stable path**

In a separate clone of the tap (do not edit `/opt/homebrew/Library/Taps/momepp/homebrew-formulae` directly — it's the live tap):

```bash
rm -rf /tmp/homebrew-formulae-edit
git clone https://github.com/MomePP/homebrew-formulae.git /tmp/homebrew-formulae-edit
```

In `/tmp/homebrew-formulae-edit/aerospace-swipe.rb`, current stable block:

```ruby
  url "https://github.com/MomePP/aerospace-swipe.git",
      tag:      "v1.0.0",
      revision: "1e96b45aae66d1afc9776ecca780f131f37d8e5a"
```

Change to (using the SHA printed in Step 3):

```ruby
  url "https://github.com/MomePP/aerospace-swipe.git",
      tag:      "v1.0.1",
      revision: "<SHA from Step 3>"
```

- [ ] **Step 5: Validate and push the formula change**

```bash
cd /tmp/homebrew-formulae-edit
git add aerospace-swipe.rb
git -c user.name=MomePP -c user.email="13793017+MomePP@users.noreply.github.com" \
  commit -m "aerospace-swipe: bump stable to v1.0.1"
```

Copy into the live tap to validate with `brew` before pushing (the live tap is what `brew style`/`brew audit`/`brew install` actually read):

```bash
cp /tmp/homebrew-formulae-edit/aerospace-swipe.rb /opt/homebrew/Library/Taps/momepp/homebrew-formulae/aerospace-swipe.rb
brew style momepp/formulae/aerospace-swipe
brew audit --formula momepp/formulae/aerospace-swipe
```

Expected: both report no offenses (same as the v1.0.0 formula update earlier — `1 file inspected, no offenses detected` / no audit errors).

If clean, push:

```bash
cd /tmp/homebrew-formulae-edit
git push origin main
```

Then fast-forward the live tap to match (safe — it's the same content already copied in, just making the tap's git history match origin):

```bash
cd /opt/homebrew/Library/Taps/momepp/homebrew-formulae
git pull --ff-only
```

- [ ] **Step 6: Reinstall and restart the real service**

```bash
brew services stop momepp/formulae/aerospace-swipe
brew uninstall aerospace-swipe
brew install momepp/formulae/aerospace-swipe
brew services start momepp/formulae/aerospace-swipe
```

This is a new build (new codesign hash), so it needs Accessibility re-granted again — same procedure as every previous rebuild this session (remove the stale `AerospaceSwipe` entry from System Settings → Privacy & Security → Accessibility if macOS doesn't prompt fresh on its own, then `brew services restart momepp/formulae/aerospace-swipe`).

- [ ] **Step 7: Final confirmation**

Do a batch of real 4-finger swipes against the actual installed service (not the foreground `./swipe` used in Tasks 3–4) and confirm the improvement holds under the real install path, not just the dev build.

- [ ] **Step 8: Clean up the scratch clone**

```bash
rm -rf /tmp/homebrew-formulae-edit
```
