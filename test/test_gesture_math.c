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
