// Deterministic scheduling checks: no AppKit, window, GPU or focus required.
#include "mcpacing.h"
#include <assert.h>
#include <stdio.h>

static void simulate(int cap, double refresh, double cpu, int variable) {
    MCPacing p = {0};
    double now = 10, start = now, finish = now;
    const int frames = 6000;
    for (int i = 0; i < frames; i++) {
        double target = (floor(now / refresh) + 1) * refresh;
        MCPacingPlan plan = mc_pacing_plan(&p, now, cap, target, refresh);
        assert(isfinite(plan.wake) && plan.wake >= now - 1e-9);
        assert(plan.wake - now < .050);
        now = plan.wake;
        if (i == 0) start = now;
        mc_pacing_started(&p, plan, now);
        // Alternating costs cross the refresh interval; occasional CPU stalls
        // must lose frames rather than trigger a burst to repay old deadlines.
        double work = cpu * (variable ? 1 + (i % 11) * .12 : 1);
        double gpu = .002;
        finish = fmax(now + work, finish) + gpu;
        mc_pacing_sample(&p, finish - now);
        now += work;
        if (variable && i % 127 == 0) now += .080;
    }
    double fps = (frames - 1) / (p.lastStart - start);
    printf("cap=%d refresh=%.1f Hz cpu=%.1f ms variable=%d: %.3f FPS\n",
        cap, 1 / refresh, cpu * 1000, variable, fps);
    assert(fps <= cap * 1.005);
    if (!variable && cpu + .002 < 1.0 / cap)
        assert(fps >= fmin(cap, 1 / refresh) * .995);
}

int main(void) {
    for (int i = 0; i < 4; i++) {
        int cap = (int[]){50,60,90,120}[i];
        simulate(cap, 1.0 / 120, .002, 0);
        simulate(cap, 1.0 / 120, .006, 1);
        simulate(cap, 1.0 / 120, .012, 1);
    }
    simulate(60, 1.0 / 60, .004, 0);
    MCPacing p = {0};
    mc_pacing_sample(&p, NAN);
    mc_pacing_sample(&p, INFINITY);
    mc_pacing_sample(&p, -1);
    mc_pacing_sample(&p, 0);
    assert(p.count == 0);
    for (int i = 0; i < 32; i++) mc_pacing_sample(&p, .020);
    MCPacingPlan plan = mc_pacing_plan(&p, 10, 120, 10.008, 1.0 / 120);
    assert(plan.wake == 10 && !plan.clockAligned);
    mc_pacing_started(&p, plan, 10);
    plan = mc_pacing_plan(&p, 10.021, 120, 10.025, 1.0 / 120);
    assert(plan.wake == 10.021 && !plan.clockAligned);
    // A long stall retires old deadlines. Subsequent fast frames obey the cap.
    plan = mc_pacing_plan(&p, 15, 60, 15.016, 1.0 / 60);
    assert(plan.wake == 15);
    mc_pacing_started(&p, plan, 15);
    for (int i = 0; i < 32; i++) mc_pacing_sample(&p, .002);
    plan = mc_pacing_plan(&p, 15.001, 60, 15.016, 1.0 / 60);
    assert(plan.wake >= 15.016 - 1e-9);
    // Refresh changes reset a stale schedule even if the user's cap is unchanged.
    p.nextFinish = 100;
    plan = mc_pacing_plan(&p, 16, 60, 16.008, 1.0 / 120);
    assert(plan.wake < 16.050);
    mc_pacing_reset(&p);
    assert(p.count == 0 && p.lastStart == 0 && p.nextFinish == 0);
    puts("PASS: pacing cap, load, stalls, rate changes and invalid timing samples");
}
