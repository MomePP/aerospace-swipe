#import "event_tap.h"
#import <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

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

@end

bool event_tap_enabled(struct event_tap* event_tap)
{
	bool result = (event_tap->handle && CGEventTapIsEnabled(event_tap->handle));
	return result;
}

bool event_tap_begin(struct event_tap* event_tap, CGEventRef (*reference)(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* userdata))
{
	event_tap->mask = 1 << NSEventTypeGesture;
	event_tap->handle = CGEventTapCreate(
		kCGHIDEventTap,
		kCGHeadInsertEventTap,
		kCGEventTapOptionListenOnly,
		event_tap->mask,
		*reference,
		event_tap);

	bool result = event_tap_enabled(event_tap);
	if (result) {
		event_tap->runloop_source = CFMachPortCreateRunLoopSource(
			kCFAllocatorDefault,
			event_tap->handle,
			0);
		CFRunLoopAddSource(CFRunLoopGetMain(),
			event_tap->runloop_source,
			kCFRunLoopDefaultMode);
	}

	return result;
}

void event_tap_end(struct event_tap* event_tap)
{
	if (event_tap_enabled(event_tap)) {
		CGEventTapEnable(event_tap->handle, false);
		CFMachPortInvalidate(event_tap->handle);
		CFRunLoopRemoveSource(CFRunLoopGetMain(),
			event_tap->runloop_source,
			kCFRunLoopCommonModes);
		CFRelease(event_tap->runloop_source);
		CFRelease(event_tap->handle);
		event_tap->handle = NULL;
	}
}
