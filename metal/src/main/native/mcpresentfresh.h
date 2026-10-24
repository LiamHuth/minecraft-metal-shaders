#pragma once
#include <stdatomic.h>
#include <stdint.h>

// A hand-off owns its staging slot: fill sequence << 2 | slot. Peek only at the
// sequence until CAS transfers ownership. The producer may replace the hand-off
// and reuse its old slot at any time. A single attempt never stalls presentation.
static inline uint64_t mc_present_take_ready(_Atomic uint64_t *handoff, uint64_t current, uint64_t completed) {
	uint64_t candidate = atomic_load(handoff);
	if (!candidate || (candidate >> 2) <= (current >> 2) || (candidate >> 2) > completed) return current;
	return atomic_compare_exchange_strong(handoff, &candidate, 0) ? candidate : current;
}
