#include "Carbon/Carbon.h"
#include "Cocoa/Cocoa.h"
#include "aerospace.h"
#include "config.h"
#import "event_tap.h"
#include "haptic.h"
#include <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <pthread.h>
#include <stdatomic.h>

static aerospace* g_aerospace = NULL;
// Lazily opened from the menu on the main thread, read on the workspace queue.
static _Atomic CFTypeRef g_haptic = NULL;
// Mutated by the menu bar on the main thread, read on the gesture and
// workspace queues — see the ConfigStore comment in config.h. Worker paths
// take one snapshot and pass it down by value; they never read the store
// directly.
static ConfigStore g_config_store;

static pthread_mutex_t g_gesture_mutex = PTHREAD_MUTEX_INITIALIZER;
static gesture_ctx g_gesture_ctx = { 0 };
static CFMutableDictionaryRef g_tracks = NULL;

// Frames are dispatched here in delivery order, one at a time — required
// since gesture processing sums displacement across frames and a
// concurrent queue does not guarantee FIFO delivery under contention.
static dispatch_queue_t g_gesture_queue;

// Dedicated to blocking workspace-switch socket I/O, kept separate from
// g_gesture_queue so I/O never delays frame processing. At most one unit
// of work is ever outstanding here — see maybe_dispatch_switch().
static dispatch_queue_t g_workspace_queue;

// maybe_dispatch_switch() and fire_single_swipe() both dispatch onto
// g_workspace_queue, so back-to-back swipes can call switch_workspace()
// from different work items at once. Without this lock,
// the list-workspaces + workspace-switch pair could interleave with
// another call's pair and act on a stale/foreign list.
static pthread_mutex_t g_aerospace_mutex = PTHREAD_MUTEX_INITIALIZER;

// Toggled from the menu on the main thread, read on the event-tap thread.
static _Atomic bool g_enabled = true;

// Menu bar app delegate
@interface AppDelegate : NSObject <NSApplicationDelegate> {
    NSMenuItem *_sensitivityItems[3];
    NSMenuItem *_fingerItems[3];
}
@property (strong, nonatomic) NSStatusItem *statusItem;
@property (strong, nonatomic) NSMenuItem *enabledMenuItem;
@property (strong, nonatomic) NSMenuItem *hapticMenuItem;
@property (strong, nonatomic) NSMenuItem *naturalSwipeMenuItem;
@property (strong, nonatomic) NSMenuItem *wrapAroundMenuItem;
@property (strong, nonatomic) NSMenuItem *skipEmptyMenuItem;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Initial menu state is built from one snapshot, so the checkmarks can't
    // disagree with each other even if a swipe is already in flight.
    Config cfg = config_store_snapshot(&g_config_store);

    // Skip menu bar if disabled in config
    if (!cfg.show_menu_bar) {
        NSLog(@"Menu bar disabled in config");
        return;
    }

    // Create status bar item
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    // Set the icon (using SF Symbol or fallback to text)
    if (@available(macOS 11.0, *)) {
        NSImage *icon = [NSImage imageWithSystemSymbolName:@"hand.draw" accessibilityDescription:@"AeroSpace Swipe"];
        [icon setTemplate:YES];
        self.statusItem.button.image = icon;
    } else {
        self.statusItem.button.title = @"⇄";
    }
    self.statusItem.button.toolTip = @"AeroSpace Swipe";

    // Create menu
    NSMenu *menu = [[NSMenu alloc] init];

    // Enabled toggle
    self.enabledMenuItem = [[NSMenuItem alloc] initWithTitle:@"Enabled" action:@selector(toggleEnabled:) keyEquivalent:@""];
    self.enabledMenuItem.target = self;
    self.enabledMenuItem.state = NSControlStateValueOn;
    [menu addItem:self.enabledMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Sensitivity submenu
    NSMenuItem *sensitivityMenuItem = [[NSMenuItem alloc] initWithTitle:@"Sensitivity" action:nil keyEquivalent:@""];
    NSMenu *sensitivityMenu = [[NSMenu alloc] init];
    NSString *sensitivityLabels[] = {@"Low", @"Medium", @"High"};
    for (int i = 0; i < 3; i++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:sensitivityLabels[i] action:@selector(setSensitivity:) keyEquivalent:@""];
        item.target = self;
        item.tag = i + 1;
        item.state = (cfg.sensitivity == i + 1) ? NSControlStateValueOn : NSControlStateValueOff;
        [sensitivityMenu addItem:item];
        _sensitivityItems[i] = item;
    }
    sensitivityMenuItem.submenu = sensitivityMenu;
    [menu addItem:sensitivityMenuItem];

    // Fingers submenu
    NSMenuItem *fingersMenuItem = [[NSMenuItem alloc] initWithTitle:@"Fingers" action:nil keyEquivalent:@""];
    NSMenu *fingersMenu = [[NSMenu alloc] init];
    for (int i = 0; i < 3; i++) {
        int fingers = i + 2;  // 2, 3, 4
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%d fingers", fingers] action:@selector(setFingers:) keyEquivalent:@""];
        item.target = self;
        item.tag = fingers;
        item.state = (cfg.fingers == fingers) ? NSControlStateValueOn : NSControlStateValueOff;
        [fingersMenu addItem:item];
        _fingerItems[i] = item;
    }
    fingersMenuItem.submenu = fingersMenu;
    [menu addItem:fingersMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Toggle options
    self.hapticMenuItem = [[NSMenuItem alloc] initWithTitle:@"Haptic Feedback" action:@selector(toggleHaptic:) keyEquivalent:@""];
    self.hapticMenuItem.target = self;
    self.hapticMenuItem.state = cfg.haptic ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.hapticMenuItem];

    self.naturalSwipeMenuItem = [[NSMenuItem alloc] initWithTitle:@"Natural Swipe" action:@selector(toggleNaturalSwipe:) keyEquivalent:@""];
    self.naturalSwipeMenuItem.target = self;
    self.naturalSwipeMenuItem.state = cfg.natural_swipe ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.naturalSwipeMenuItem];

    self.wrapAroundMenuItem = [[NSMenuItem alloc] initWithTitle:@"Wrap Around" action:@selector(toggleWrapAround:) keyEquivalent:@""];
    self.wrapAroundMenuItem.target = self;
    self.wrapAroundMenuItem.state = cfg.wrap_around ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.wrapAroundMenuItem];

    self.skipEmptyMenuItem = [[NSMenuItem alloc] initWithTitle:@"Skip Empty" action:@selector(toggleSkipEmpty:) keyEquivalent:@""];
    self.skipEmptyMenuItem.target = self;
    self.skipEmptyMenuItem.state = cfg.skip_empty ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.skipEmptyMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Quit
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
}

- (void)toggleEnabled:(id)sender {
    g_enabled = !g_enabled;
    self.enabledMenuItem.state = g_enabled ? NSControlStateValueOn : NSControlStateValueOff;

    if (@available(macOS 11.0, *)) {
        NSString *iconName = g_enabled ? @"hand.draw" : @"hand.raised.slash";
        NSImage *icon = [NSImage imageWithSystemSymbolName:iconName accessibilityDescription:@"AeroSpace Swipe"];
        [icon setTemplate:YES];
        self.statusItem.button.image = icon;
    }

    NSLog(@"AeroSpace Swipe %@", g_enabled ? @"enabled" : @"disabled");
}

- (void)setSensitivity:(NSMenuItem *)sender {
    int level = (int)sender.tag;

    config_store_set_sensitivity(&g_config_store, level);
    Config cfg = config_store_snapshot(&g_config_store);

    // Update checkmarks (1=Low, 2=Medium, 3=High)
    for (int i = 0; i < 3; i++) {
        _sensitivityItems[i].state = (i + 1 == level) ? NSControlStateValueOn : NSControlStateValueOff;
    }

    NSLog(@"Sensitivity set to %d (distance=%.2f, fast=%.2fx@vel%.2f)",
          level, cfg.distance_pct, cfg.fast_distance_factor, cfg.fast_velocity_threshold);
}

- (void)setFingers:(NSMenuItem *)sender {
    int fingers = (int)sender.tag;

    config_store_set_fingers(&g_config_store, fingers);

    // Update checkmarks
    for (int i = 0; i < 3; i++) {
        _fingerItems[i].state = (_fingerItems[i].tag == fingers) ? NSControlStateValueOn : NSControlStateValueOff;
    }

    NSLog(@"Fingers set to %d", fingers);
}

- (void)toggleHaptic:(id)sender {
    bool haptic = config_store_toggle_haptic(&g_config_store);

    self.hapticMenuItem.state = haptic ? NSControlStateValueOn : NSControlStateValueOff;

    // Initialize haptic if enabling and not already initialized
    if (haptic && !g_haptic) {
        g_haptic = haptic_open_default();
        if (!g_haptic) {
            NSLog(@"Warning: Failed to initialize haptic actuator");
        }
    }

    NSLog(@"Haptic feedback %@", haptic ? @"enabled" : @"disabled");
}

- (void)toggleNaturalSwipe:(id)sender {
    bool natural = config_store_toggle_natural_swipe(&g_config_store);

    self.naturalSwipeMenuItem.state = natural ? NSControlStateValueOn : NSControlStateValueOff;

    NSLog(@"Natural swipe %@", natural ? @"enabled" : @"disabled");
}

- (void)toggleWrapAround:(id)sender {
    bool wrap_around = config_store_toggle_wrap_around(&g_config_store);

    self.wrapAroundMenuItem.state = wrap_around ? NSControlStateValueOn : NSControlStateValueOff;

    NSLog(@"Wrap around %@", wrap_around ? @"enabled" : @"disabled");
}

- (void)toggleSkipEmpty:(id)sender {
    bool skip_empty = config_store_toggle_skip_empty(&g_config_store);

    self.skipEmptyMenuItem.state = skip_empty ? NSControlStateValueOn : NSControlStateValueOff;

    NSLog(@"Skip empty %@", skip_empty ? @"enabled" : @"disabled");
}

- (void)quit:(id)sender {
    [[NSApplication sharedApplication] terminate:nil];
}

@end

// cached_workspaces lets a caller reuse one aerospace_list_workspaces()
// snapshot across multiple calls within the same continuous gesture
// (window-to-workspace assignment doesn't change from focus-switching
// alone, so a stale-by-milliseconds cache is still correct). Pass a
// pointer to a caller-owned char* that starts NULL; this function fetches
// once and fills it in, and reuses it on subsequent calls.
static void switch_workspace(const char* ws, char** cached_workspaces, const Config* cfg)
{
	pthread_mutex_lock(&g_aerospace_mutex);

	if (cfg->skip_empty || cfg->wrap_around) {
		char* workspaces = cached_workspaces ? *cached_workspaces : NULL;
		if (!workspaces) {
			workspaces = aerospace_list_workspaces(g_aerospace, !cfg->skip_empty);
			if (!workspaces) {
				fprintf(stderr, "Error: Unable to retrieve workspace list.\n");
				pthread_mutex_unlock(&g_aerospace_mutex);
				return;
			}
			if (cached_workspaces)
				*cached_workspaces = workspaces;
		}
		char* result = aerospace_workspace(g_aerospace, cfg->wrap_around, ws, workspaces);
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

	if (cfg->haptic && g_haptic)
		haptic_actuate(g_haptic, 3);

	pthread_mutex_unlock(&g_aerospace_mutex);
}

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
static void maybe_dispatch_switch(gesture_ctx* ctx, Config cfg)
{
	if (ctx->dispatch_in_flight)
		return;
	ctx->dispatch_in_flight = true;

	// cfg is captured by value: the whole convergence loop runs against the
	// config that was live when this gesture frame was processed, so a menu
	// toggle mid-flight can't flip direction or threshold under it.
	dispatch_async(g_workspace_queue, ^{
		for (;;) {
			pthread_mutex_lock(&g_gesture_mutex);
			int target = compute_target_step(ctx->acc_dx, cfg.distance_pct, cfg.max_steps);
			int delta = target - ctx->executed_step;
			pthread_mutex_unlock(&g_gesture_mutex);

			if (delta == 0)
				break;

			int step_dir = delta > 0 ? 1 : -1;
			switch_workspace(step_dir > 0 ? cfg.swipe_right : cfg.swipe_left,
				&ctx->cached_workspace_list, &cfg);

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
// feedback in this mode. Tried firing live instead (while fingers were
// still down, for haptic perceptibility) but it felt worse in practice —
// reverted to release-based firing per explicit testing feedback.
static void fire_single_swipe(gesture_ctx* ctx, Config cfg)
{
	bool fast = fabsf(ctx->peak_velx) >= cfg.fast_velocity_threshold;
	float need = fast ? cfg.distance_pct * cfg.fast_distance_factor : cfg.distance_pct;

	if (fabsf(ctx->acc_dx) < need)
		return;

	int step_dir = ctx->acc_dx > 0 ? 1 : -1;
	const char* ws = step_dir > 0 ? cfg.swipe_right : cfg.swipe_left;
	char** cache = &ctx->cached_workspace_list;

	dispatch_async(g_workspace_queue, ^{
		switch_workspace(ws, cache, &cfg);
	});
}

static void calculate_touch_averages(touch* touches, int count,
	float* avg_x, float* avg_y, float* avg_vel,
	float* min_x, float* max_x, float* min_y, float* max_y)
{
	*avg_x = *avg_y = *avg_vel = 0;
	*min_x = *min_y = 1;
	*max_x = *max_y = 0;

	for (int i = 0; i < count; ++i) {
		*avg_x += touches[i].x;
		*avg_y += touches[i].y;
		*avg_vel += touches[i].velocity;

		if (touches[i].x < *min_x)
			*min_x = touches[i].x;
		if (touches[i].x > *max_x)
			*max_x = touches[i].x;
		if (touches[i].y < *min_y)
			*min_y = touches[i].y;
		if (touches[i].y > *max_y)
			*max_y = touches[i].y;
	}

	*avg_x /= count;
	*avg_y /= count;
	*avg_vel /= count;
}

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
	float avg_x, float avg_y, float avg_vel, Config cfg)
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

	if (ctx->axis != AXIS_HORIZONTAL || !cfg.multi_swipe)
		return;

	int target = compute_target_step(ctx->acc_dx, cfg.distance_pct, cfg.max_steps);
	if (target != ctx->executed_step)
		maybe_dispatch_switch(ctx, cfg);
}

static void gestureCallback(touch* touches, int count)
{
	if (!g_enabled)
		return;

	// One snapshot per frame: every decision this callback makes — and every
	// switch it dispatches — sees a single coherent view of the config.
	Config cfg = config_store_snapshot(&g_config_store);

	pthread_mutex_lock(&g_gesture_mutex);

	gesture_ctx* ctx = &g_gesture_ctx;

	if (count == 0) {
		if (ctx->state == GS_TRACKING && !cfg.multi_swipe
			&& ctx->axis == AXIS_HORIZONTAL)
			fire_single_swipe(ctx, cfg);
		reset_gesture_state(ctx);
		goto unlock;
	}

	if (ctx->state == GS_IDLE) {
		if (count != cfg.fingers) {
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
		handle_tracking_state(ctx, touches, count, avg_x, avg_y, avg_vel, cfg);
	}

unlock:
	pthread_mutex_unlock(&g_gesture_mutex);
}

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

static CGEventRef key_handler(__unused CGEventTapProxy proxy, CGEventType type,
	CGEventRef event, void* ref)
{
	struct event_tap* event_tap_ref = (struct event_tap*)ref;

	if (!AXIsProcessTrusted()) {
		NSLog(@"Accessibility permission lost, disabling tap.");
		event_tap_end(event_tap_ref);
		return event;
	}

	if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
		NSLog(@"Event-tap re-enabled.");
		CGEventTapEnable(event_tap_ref->handle, true);
		return event;
	}

	if (type != NSEventTypeGesture)
		return event;

	NSEvent* ev = [NSEvent eventWithCGEvent:event];
	NSSet<NSTouch*>* touches = ev.allTouches;

	if (!touches.count)
		return event;

	process_touches(touches);

	return event;
}

static void acquire_lockfile(void)
{
	char* user = getenv("USER");
	if (!user)
		printf("Error: User variable not set.\n"), exit(1);

	char buffer[256];
	snprintf(buffer, 256, "/tmp/aerospace-swipe-%s.lock", user);

	int handle = open(buffer, O_CREAT | O_WRONLY, 0600);
	if (handle == -1) {
		printf("Error: Could not create lock-file.\n");
		exit(1);
	}

	struct flock lockfd = {
		.l_start = 0,
		.l_len = 0,
		.l_pid = getpid(),
		.l_type = F_WRLCK,
		.l_whence = SEEK_SET
	};

	if (fcntl(handle, F_SETLK, &lockfd) == -1) {
		printf("Error: Could not acquire lock-file.\naerospace-swipe already running?\n");
		exit(1);
	}
}

void waitForAccessibilityAndRestart(void)
{
	while (!AXIsProcessTrusted()) {
		NSLog(@"Waiting for accessibility permission...");
		sleep(1);
	}

	NSLog(@"Accessibility permission granted. Restarting app...");

	NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
	[[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:bundlePath] configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
	exit(0);
}

int main(int argc, const char* argv[])
{
	signal(SIGCHLD, SIG_IGN);
	signal(SIGPIPE, SIG_IGN);

	acquire_lockfile();

	@autoreleasepool {
		NSDictionary* options = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};

		if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
			NSLog(@"Accessibility permission not granted. Prompting user...");
			AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);

			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
				waitForAccessibilityAndRestart();
			});

			CFRunLoopRun();
		}

		NSLog(@"Accessibility permission granted. Continuing app initialization...");

		config_store_init(&g_config_store, load_config());
		Config cfg = config_store_snapshot(&g_config_store);
		NSLog(@"Loaded config: fingers=%d, skip_empty=%s, wrap_around=%s, haptic=%s, multi_swipe=%s, max_steps=%d, swipe_left='%s', swipe_right='%s'",
			cfg.fingers,
			cfg.skip_empty ? "YES" : "NO",
			cfg.wrap_around ? "YES" : "NO",
			cfg.haptic ? "YES" : "NO",
			cfg.multi_swipe ? "YES" : "NO",
			cfg.max_steps,
			cfg.swipe_left,
			cfg.swipe_right);

		g_aerospace = aerospace_new(NULL);
		if (!g_aerospace) {
			fprintf(stderr, "Error: Failed to initialize Aerospace client.\n");
			exit(EXIT_FAILURE);
		}

		if (cfg.haptic) {
			g_haptic = haptic_open_default();
			if (!g_haptic)
				fprintf(stderr, "Warning: Failed to initialize haptic actuator. Continuing without haptics.\n");
		}

		g_tracks = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);

		g_gesture_queue = dispatch_queue_create("aerospace-swipe.gesture", DISPATCH_QUEUE_SERIAL);
		g_workspace_queue = dispatch_queue_create("aerospace-swipe.workspace", DISPATCH_QUEUE_SERIAL);

		event_tap_begin(&g_event_tap, key_handler);

		// Set up NSApplication with our delegate for menu bar
		NSApplication *app = [NSApplication sharedApplication];
		AppDelegate *delegate = [[AppDelegate alloc] init];
		app.delegate = delegate;

		// Activate as accessory (menu bar only, no dock icon)
		[app setActivationPolicy:NSApplicationActivationPolicyAccessory];

		[app run];
		return 0;
	}
}
