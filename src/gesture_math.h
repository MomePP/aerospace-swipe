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
