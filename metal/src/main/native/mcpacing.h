// Render-thread-only timing policy. No Metal ownership, timers or OS calls here.
#pragma once
#include <math.h>
#include <string.h>

#define MC_PACING_HISTORY 32
typedef struct {
    double costs[MC_PACING_HISTORY];
    unsigned count, cursor;
    double nextFinish, lastStart, refresh, budget;
    int cap;
} MCPacing;

typedef struct {
    double wake, finish, nextFinish, budget;
    int clockAligned;
} MCPacingPlan;

static inline void mc_pacing_reset(MCPacing *p) { memset(p, 0, sizeof(*p)); }

static inline void mc_pacing_sample(MCPacing *p, double elapsed) {
    // Ignore invalid/error timestamps. Long valid frames are retained; a single
    // loading/GC spike should not dictate the next half-second of frame timing.
    if (!isfinite(elapsed) || elapsed <= 0 || elapsed > 1) return;
    p->costs[p->cursor++ % MC_PACING_HISTORY] = elapsed;
    if (p->count < MC_PACING_HISTORY) p->count++;
}

static inline double mc_pacing_budget(MCPacing *p, double refresh) {
    double value = refresh * .6;
    if (p->count >= 4) {
        double sorted[MC_PACING_HISTORY];
        memcpy(sorted, p->costs, p->count * sizeof(double));
        for (unsigned i = 1; i < p->count; i++) {
            double v = sorted[i];
            unsigned j = i;
            while (j && sorted[j - 1] > v) { sorted[j] = sorted[j - 1]; j--; }
            sorted[j] = v;
        }
        value = sorted[(p->count * 9 + 9) / 10 - 1]; // nearest-rank p90
    }
    value += fmin(.0015, refresh * .12); // compositor/CPU wake-up headroom
    // Adapt upward promptly, but avoid shifting input sampling rapidly as load falls.
    p->budget = p->budget <= 0 ? value : fmax(value, p->budget * .9 + value * .1);
    return p->budget;
}

static inline double mc_pacing_align(double time, double target, double refresh) {
    return target + ceil((time - target) / refresh - 1e-7) * refresh;
}

static inline MCPacingPlan mc_pacing_plan(MCPacing *p, double now, int cap,
                                         double target, double refresh) {
    // Caller supplies a recent display callback. Use its observed interval, not
    // maximumFramesPerSecond: power/display changes can reduce the actual cadence.
    if (p->cap != cap || p->refresh <= 0 || fabs(refresh - p->refresh) > p->refresh * .05) {
        p->nextFinish = 0;
        p->cap = cap;
        p->refresh = refresh;
        p->budget = 0;
    }
    double period = 1.0 / cap;
    double budget = mc_pacing_budget(p, refresh);
    MCPacingPlan plan = {.budget = budget};
    // A slow CPU/GPU frame already supplies pacing. Do not make it wait for the
    // next display tick as well, nor render a burst to catch up with old deadlines.
    if (budget >= period || (p->lastStart > 0 && now >= p->lastStart + period)) {
        plan.wake = fmax(now, p->lastStart > 0 ? p->lastStart + period : now);
        plan.finish = plan.wake + budget;
        plan.nextFinish = 0;
        return plan;
    }
    double due = p->nextFinish > 0 ? p->nextFinish : now + budget;
    double finish = mc_pacing_align(due, target, refresh);
    if (finish < now + budget) {
        // A missed start should not cost another refresh just to realign. Start
        // immediately and rebuild the grid from the next frame instead.
        plan.wake = now;
        plan.finish = now + budget;
        plan.nextFinish = 0;
        return plan;
    }
    plan.wake = finish - budget;
    plan.finish = finish;
    plan.nextFinish = due + period;
    plan.clockAligned = 1;
    return plan;
}

static inline void mc_pacing_started(MCPacing *p, MCPacingPlan plan, double now) {
    p->lastStart = now;
    p->nextFinish = plan.nextFinish;
}
