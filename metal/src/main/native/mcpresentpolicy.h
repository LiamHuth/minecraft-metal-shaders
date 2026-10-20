// Small, platform-independent presentation policy. The caller serializes feedback access.
#pragma once
#include <math.h>
#include <stdint.h>

enum { MC_PRESENT_CLOCK, MC_PRESENT_READY, MC_PRESENT_DURATION, MC_PRESENT_ADAPTIVE };
#define MC_PRESENT_RECEIPTS 64
typedef struct {
    uint64_t sequence;
    double submitted, completed, shown;
    int failed;
} MCPresentReceipt;
typedef struct {
    MCPresentReceipt receipts[MC_PRESENT_RECEIPTS];
    uint64_t submitted, latestShown;
    double gpuAverage;
} MCPresentFeedback;
typedef struct { unsigned gpu, display; double oldest; } MCPresentBacklog;

static inline uint64_t mc_present_record(MCPresentFeedback *p, double now) {
    uint64_t seq = ++p->submitted;
    p->receipts[seq % MC_PRESENT_RECEIPTS] = (MCPresentReceipt){.sequence=seq, .submitted=now};
    return seq;
}
static inline void mc_present_completed(MCPresentFeedback *p, uint64_t seq,
                                         double now, double gpuDuration, int failed) {
    MCPresentReceipt *r = &p->receipts[seq % MC_PRESENT_RECEIPTS];
    if (r->sequence != seq) return; // late callback after a bounded ring wrap
    r->completed = now;
    r->failed = failed;
    if (!failed && isfinite(gpuDuration) && gpuDuration > 0 && gpuDuration < .250)
        p->gpuAverage = p->gpuAverage > 0 ? p->gpuAverage * .9 + gpuDuration * .1 : gpuDuration;
}
static inline void mc_present_shown(MCPresentFeedback *p, uint64_t seq, double shown) {
    if (!isfinite(shown) || shown <= 0 || seq > p->submitted) return;
    MCPresentReceipt *r = &p->receipts[seq % MC_PRESENT_RECEIPTS];
    if (r->sequence != seq) return;
    r->shown = shown;
    if (seq > p->latestShown) p->latestShown = seq;
}
static inline MCPresentBacklog mc_present_backlog(const MCPresentFeedback *p) {
    MCPresentBacklog b = {0};
    for (unsigned i = 0; i < MC_PRESENT_RECEIPTS; i++) {
        const MCPresentReceipt *r = &p->receipts[i];
        if (!r->sequence || r->failed || r->shown > 0) continue;
        // A newer confirmed presentation supersedes older completed images, even
        // if their notifications were omitted. Never infer GPU resource retirement.
        if (r->completed > 0 && r->sequence <= p->latestShown) continue;
        if (r->completed > 0) b.display++; else b.gpu++;
        if (!b.oldest || r->submitted < b.oldest) b.oldest = r->submitted;
    }
    return b;
}
static inline double mc_present_duration(int mode, int cap, double gpuAverage,
                                          double maximumInterval, int adaptiveEligible) {
    if (mode < MC_PRESENT_DURATION || cap <= 0) return 0;
    double duration = 1.0 / cap;
    // GPU duration excludes time spent queued for presentation. Do not feed
    // compositor delay back into the render budget and progressively slow down.
    if (mode == MC_PRESENT_ADAPTIVE && adaptiveEligible && isfinite(gpuAverage) && gpuAverage > 0) {
        double learned = gpuAverage * 1.05;
        if (maximumInterval > 0) learned = fmin(learned, maximumInterval);
        duration = fmax(duration, learned);
    }
    return duration;
}
static inline double mc_present_wait_limit(int cap) {
    return fmin(.050, fmax(.025, 3.0 / (cap > 0 ? cap : 120)));
}
