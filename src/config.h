#include <CoreFoundation/CoreFoundation.h>
#define CONFIG_H

#include "yyjson.h"
#include <pthread.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
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
	CFTimeInterval palm_age;
	float palm_velocity;
	float fast_distance_factor;   // For fast swipes, trigger at this fraction of distance_pct
	float fast_velocity_threshold; // Minimum velocity to qualify as "fast"
	bool multi_swipe;    // fire multiple workspace switches within one continuous gesture
	int max_steps;       // cap on workspaces crossed per gesture when multi_swipe is on
	const char* swipe_left;
	const char* swipe_right;
} Config;

// Apply sensitivity level: 1=Low, 2=Medium, 3=High
// All levels support early triggering on fast intentional swipes (60% of threshold)
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

static Config default_config()
{
	Config config;
	config.natural_swipe = false;
	config.wrap_around = true;
	config.haptic = false;
	config.skip_empty = true;
	config.show_menu_bar = true;
	config.fingers = 3;
	config.sensitivity = 2;          // Default sensitivity level (1=Low, 2=Medium, 3=High)
	config.settle_factor = 0.25f;    // ≤25% of flick speed -> ended (unused, predates this change)
	config.palm_disp = 0.025;        // 2.5% pad from origin
	config.palm_age = 0.06;          // 60ms before judgment
	config.palm_velocity = 0.1;      // 10% of pad dimension per second
	config.fast_distance_factor = 0.60f;   // Fast swipes can trigger at 60% of normal distance
	config.fast_velocity_threshold = 0.35f; // Velocity needed for fast-trigger
	config.multi_swipe = true;
	config.max_steps = 5;
	config.swipe_left = "prev";
	config.swipe_right = "next";

	// Apply default sensitivity
	apply_sensitivity(&config, config.sensitivity);
	return config;
}

static int read_file_to_buffer(const char* path, char** out, size_t* size)
{
	FILE* file = fopen(path, "rb");
	if (!file)
		return 0;

	struct stat st;
	if (stat(path, &st) != 0) {
		fclose(file);
		return 0;
	}
	*size = st.st_size;

	*out = (char*)malloc(*size + 1);
	if (!*out) {
		fclose(file);
		return 0;
	}

	fread(*out, 1, *size, file);
	(*out)[*size] = '\0';
	fclose(file);
	return 1;
}

static Config load_config()
{
	Config config = default_config();

	char* buffer = NULL;
	size_t buffer_size = 0;
	const char* paths[] = { "./config.json", NULL };

	char fallback_path[512];
	struct passwd* pw = getpwuid(getuid());
	if (pw) {
		snprintf(fallback_path, sizeof(fallback_path),
			"%s/.config/aerospace-swipe/config.json", pw->pw_dir);
		paths[1] = fallback_path;
	}

	for (int i = 0; i < 2; ++i) {
		if (paths[i] && read_file_to_buffer(paths[i], &buffer, &buffer_size)) {
			printf("Loaded config from: %s\n", paths[i]);
			break;
		}
	}

	if (!buffer) {
		fprintf(stderr, "Using default configuration.\n");
		return config;
	}

	yyjson_doc* doc = yyjson_read(buffer, buffer_size, 0);
	free(buffer);
	if (!doc) {
		fprintf(stderr, "Failed to parse config JSON. Using defaults.\n");
		return config;
	}

	yyjson_val* root = yyjson_doc_get_root(doc);
	yyjson_val* item;

	item = yyjson_obj_get(root, "natural_swipe");
	if (item && yyjson_is_bool(item))
		config.natural_swipe = yyjson_get_bool(item);

	item = yyjson_obj_get(root, "wrap_around");
	if (item && yyjson_is_bool(item))
		config.wrap_around = yyjson_get_bool(item);

	item = yyjson_obj_get(root, "haptic");
	if (item && yyjson_is_bool(item))
		config.haptic = yyjson_get_bool(item);

	item = yyjson_obj_get(root, "skip_empty");
	if (item && yyjson_is_bool(item))
		config.skip_empty = yyjson_get_bool(item);

	item = yyjson_obj_get(root, "fingers");
	if (item && yyjson_is_int(item))
		config.fingers = (int)yyjson_get_int(item);

	item = yyjson_obj_get(root, "distance_pct");
	if (item && yyjson_is_real(item))
		config.distance_pct = (float)yyjson_get_real(item);

	item = yyjson_obj_get(root, "settle_factor");
	if (item && yyjson_is_real(item))
		config.settle_factor = (float)yyjson_get_real(item);

	item = yyjson_obj_get(root, "show_menu_bar");
	if (item && yyjson_is_bool(item))
		config.show_menu_bar = yyjson_get_bool(item);

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

	config.swipe_left = config.natural_swipe ? "next" : "prev";
	config.swipe_right = config.natural_swipe ? "prev" : "next";

	yyjson_doc_free(doc);
	return config;
}

// A Config that is mutated from one thread (the menu bar, on the main thread)
// while others read it (the gesture and workspace queues).
//
// Readers never touch .config directly — they take a whole-struct snapshot and
// work from that. Beyond making the reads well-defined, this is what keeps
// fields that are only meaningful *together* consistent: the sensitivity triple
// (distance_pct + fast_distance_factor + fast_velocity_threshold) and the
// direction pair (swipe_left + swipe_right). A reader that caught one of those
// groups half-written would swipe the wrong way or use a mismatched threshold.
//
// The mutex is a leaf: never acquire another lock while holding it. Callers
// that need to log or update UI should do so after the mutator returns.
typedef struct {
	Config config;
	pthread_mutex_t mutex;
} ConfigStore;

static inline void config_store_init(ConfigStore* store, Config config)
{
	store->config = config;
	pthread_mutex_init(&store->mutex, NULL);
}

static inline Config config_store_snapshot(ConfigStore* store)
{
	pthread_mutex_lock(&store->mutex);
	Config config = store->config;
	pthread_mutex_unlock(&store->mutex);
	return config;
}

static inline void config_store_set_sensitivity(ConfigStore* store, int level)
{
	pthread_mutex_lock(&store->mutex);
	apply_sensitivity(&store->config, level);
	pthread_mutex_unlock(&store->mutex);
}

static inline void config_store_set_fingers(ConfigStore* store, int fingers)
{
	pthread_mutex_lock(&store->mutex);
	store->config.fingers = fingers;
	pthread_mutex_unlock(&store->mutex);
}

static inline bool config_store_toggle_natural_swipe(ConfigStore* store)
{
	pthread_mutex_lock(&store->mutex);
	bool natural_swipe = store->config.natural_swipe = !store->config.natural_swipe;
	store->config.swipe_left = natural_swipe ? "next" : "prev";
	store->config.swipe_right = natural_swipe ? "prev" : "next";
	pthread_mutex_unlock(&store->mutex);
	return natural_swipe;
}

static inline bool config_store_toggle_haptic(ConfigStore* store)
{
	pthread_mutex_lock(&store->mutex);
	bool haptic = store->config.haptic = !store->config.haptic;
	pthread_mutex_unlock(&store->mutex);
	return haptic;
}

static inline bool config_store_toggle_wrap_around(ConfigStore* store)
{
	pthread_mutex_lock(&store->mutex);
	bool wrap_around = store->config.wrap_around = !store->config.wrap_around;
	pthread_mutex_unlock(&store->mutex);
	return wrap_around;
}

static inline bool config_store_toggle_skip_empty(ConfigStore* store)
{
	pthread_mutex_lock(&store->mutex);
	bool skip_empty = store->config.skip_empty = !store->config.skip_empty;
	pthread_mutex_unlock(&store->mutex);
	return skip_empty;
}
