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
