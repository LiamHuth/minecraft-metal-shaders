// Concurrent ownership checks for the same claim operation used by pqRefresh.
#include "../../metal/src/main/native/mcpresentfresh.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>

static _Atomic uint64_t handoff, completed, owner[3];
static uint64_t payload[3];
static _Atomic int done;
static unsigned checked, replaced;

static void release_slot(uint64_t token) {
	assert(token);
	assert(payload[token & 3] == token);
	assert(atomic_compare_exchange_strong(&owner[token & 3], &token, 0));
}

static void *producer(void *unused) {
	(void)unused;
	for (uint64_t n = 1; n <= 300000; n++) {
		unsigned k = n % 3;
		uint64_t empty = 0, token = n << 2 | k;
		while (!atomic_compare_exchange_strong(&owner[k], &empty, token)) { empty = 0; sched_yield(); }
		payload[k] = token;
		// Some published frames are not yet ready. A consumer must never replace
		// a ready frame with one of these just because it has a newer sequence.
		atomic_store(&completed, n - (n % 3 == 0));
		uint64_t old = atomic_exchange(&handoff, token);
		if (old) release_slot(old);
		if (n % 13 == 0) sched_yield();
		atomic_store(&completed, n);
	}
	atomic_store(&done, 1);
	return NULL;
}

static void *consumer(void *unused) {
	(void)unused;
	uint64_t last = 0;
	for (;;) {
		uint64_t current = atomic_exchange(&handoff, 0);
		if (!current) { if (atomic_load(&done) && !atomic_load(&handoff)) break; sched_yield(); continue; }
		if (checked % 7 == 0) sched_yield(); // models blocking drawable acquisition
		uint64_t ready = atomic_load(&completed);
		uint64_t selected = mc_present_take_ready(&handoff, current, ready);
		if (selected != current) {
			assert((selected >> 2) <= ready);
			assert((selected >> 2) > (current >> 2));
			release_slot(current);
			replaced++;
		}
		assert((selected >> 2) > last);
		last = selected >> 2;
		release_slot(selected);
		checked++;
	}
	return NULL;
}

int main(void) {
	uint64_t current = 4, next = 9;
	assert(mc_present_take_ready(&handoff, current, 100) == current);
	atomic_store(&handoff, next);
	assert(mc_present_take_ready(&handoff, current, 1) == current);
	assert(atomic_load(&handoff) == next);
	assert(mc_present_take_ready(&handoff, current, 2) == next);
	assert(atomic_load(&handoff) == 0);
	atomic_store(&handoff, current);
	assert(mc_present_take_ready(&handoff, next, 100) == next);
	assert(atomic_exchange(&handoff, 0) == current);
	pthread_t a, b;
	assert(!pthread_create(&a, NULL, producer, NULL));
	assert(!pthread_create(&b, NULL, consumer, NULL));
	assert(!pthread_join(a, NULL));
	assert(!pthread_join(b, NULL));
	for (int k = 0; k < 3; k++) assert(!atomic_load(&owner[k]));
	assert(checked && replaced);
	printf("PASS: empty/pending/ready/stale selection; 300000 concurrent publications, %u consumed, %u refreshed; no double ownership or leaked slots\n", checked, replaced);
}
