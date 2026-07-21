// Concurrency test for ConfigStore (src/config.h), the store main.m keeps
// g_config in. The menu bar mutates it on the main thread while the gesture
// and workspace queues snapshot it, so this drives the same code from a
// writer thread and several reader threads at once.
//
// Two failure modes are in scope:
//
//   1. A torn snapshot. Some fields are only meaningful as a group — the
//      sensitivity triple and the swipe_left/swipe_right pair. A reader that
//      caught one group half-written would use a mismatched threshold or
//      swipe the wrong way. The assertions below reject any such snapshot.
//   2. A data race. Built with -fsanitize=thread, so unsynchronized access
//      is reported even when the resulting values happen to look plausible.
//
// Built with TSan by the makefile — see the test_config_store target.

#include "../src/config.h"

#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#define WRITER_ITERATIONS 20000
#define READER_THREADS 4

static ConfigStore g_store;
static atomic_bool g_writer_done = false;
static atomic_int g_torn_snapshots = 0;
static atomic_long g_snapshots_checked = 0;

// Every field group in a snapshot must agree with itself. apply_sensitivity()
// is its own oracle here: re-deriving the triple from the snapshot's own
// sensitivity level must reproduce the triple the snapshot carries.
static void check_snapshot(const Config* cfg)
{
	const char* expect_left = cfg->natural_swipe ? "next" : "prev";
	const char* expect_right = cfg->natural_swipe ? "prev" : "next";

	if (strcmp(cfg->swipe_left, expect_left) != 0
		|| strcmp(cfg->swipe_right, expect_right) != 0) {
		fprintf(stderr,
			"torn direction pair: natural_swipe=%s but left='%s' right='%s'\n",
			cfg->natural_swipe ? "true" : "false", cfg->swipe_left, cfg->swipe_right);
		atomic_fetch_add(&g_torn_snapshots, 1);
		return;
	}

	Config expected = *cfg;
	apply_sensitivity(&expected, cfg->sensitivity);

	if (expected.distance_pct != cfg->distance_pct
		|| expected.fast_distance_factor != cfg->fast_distance_factor
		|| expected.fast_velocity_threshold != cfg->fast_velocity_threshold) {
		fprintf(stderr,
			"torn sensitivity triple: level=%d carries distance=%.4f fast=%.4f vel=%.4f, "
			"expected distance=%.4f fast=%.4f vel=%.4f\n",
			cfg->sensitivity, cfg->distance_pct, cfg->fast_distance_factor,
			cfg->fast_velocity_threshold, expected.distance_pct,
			expected.fast_distance_factor, expected.fast_velocity_threshold);
		atomic_fetch_add(&g_torn_snapshots, 1);
		return;
	}

	if (cfg->fingers < 2 || cfg->fingers > 4) {
		fprintf(stderr, "implausible fingers value: %d\n", cfg->fingers);
		atomic_fetch_add(&g_torn_snapshots, 1);
	}
}

// Mirrors what the menu handlers in main.m do, minus the AppKit.
static void* writer_thread(void* arg)
{
	(void)arg;

	for (int i = 0; i < WRITER_ITERATIONS; ++i) {
		config_store_toggle_natural_swipe(&g_store);
		config_store_set_sensitivity(&g_store, (i % 3) + 1);
		config_store_set_fingers(&g_store, (i % 3) + 2);
		config_store_toggle_wrap_around(&g_store);
		config_store_toggle_skip_empty(&g_store);
		config_store_toggle_haptic(&g_store);
	}

	atomic_store(&g_writer_done, true);
	return NULL;
}

static void* reader_thread(void* arg)
{
	(void)arg;

	long checked = 0;
	while (!atomic_load(&g_writer_done)) {
		Config cfg = config_store_snapshot(&g_store);
		check_snapshot(&cfg);
		checked++;
	}

	atomic_fetch_add(&g_snapshots_checked, checked);
	return NULL;
}

int main(void)
{
	config_store_init(&g_store, default_config());

	pthread_t writer;
	pthread_t readers[READER_THREADS];

	if (pthread_create(&writer, NULL, writer_thread, NULL) != 0) {
		fprintf(stderr, "failed to spawn writer thread\n");
		return 1;
	}
	for (int i = 0; i < READER_THREADS; ++i) {
		if (pthread_create(&readers[i], NULL, reader_thread, NULL) != 0) {
			fprintf(stderr, "failed to spawn reader thread %d\n", i);
			return 1;
		}
	}

	pthread_join(writer, NULL);
	for (int i = 0; i < READER_THREADS; ++i)
		pthread_join(readers[i], NULL);

	long checked = atomic_load(&g_snapshots_checked);
	int torn = atomic_load(&g_torn_snapshots);

	if (torn != 0) {
		fprintf(stderr, "FAIL: %d torn snapshot(s) out of %ld checked\n", torn, checked);
		return 1;
	}

	// A run that never overlapped writer and readers would pass vacuously.
	if (checked < 1000) {
		fprintf(stderr,
			"FAIL: only %ld snapshots checked — readers did not meaningfully "
			"overlap the writer, so this run proves nothing\n",
			checked);
		return 1;
	}

	printf("All config_store tests passed (%ld concurrent snapshots checked).\n", checked);
	return 0;
}
