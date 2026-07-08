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
