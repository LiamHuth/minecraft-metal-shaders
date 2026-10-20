#include "mcpresentpolicy.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    MCPresentFeedback p = {0};
    uint64_t a = mc_present_record(&p, 1), b = mc_present_record(&p, 1.01);
    assert(mc_present_backlog(&p).gpu == 2);
    mc_present_completed(&p, a, 1.02, .006, 0);
    assert(mc_present_backlog(&p).gpu == 1 && mc_present_backlog(&p).display == 1);
    mc_present_completed(&p, b, 1.03, .010, 0);
    assert(mc_present_backlog(&p).display == 2);
    // A missed notification cannot strand a completed older frame when a newer
    // image is confirmed. This does not pretend the older timestamp was received.
    mc_present_shown(&p, b, 1.04);
    assert(mc_present_backlog(&p).display == 0);
    assert(p.receipts[a % MC_PRESENT_RECEIPTS].shown == 0);
    mc_present_shown(&p, a, 1.035); // out-of-order notification
    assert(p.latestShown == b);
    uint64_t c = mc_present_record(&p, 1.05);
    mc_present_shown(&p, c, NAN);
    assert(mc_present_backlog(&p).gpu == 1);
    mc_present_completed(&p, c, 1.06, 0, 1);
    assert(mc_present_backlog(&p).gpu == 0);
    // A late receipt cannot modify a reused slot or the latest shown sequence.
    for (int i = 0; i < MC_PRESENT_RECEIPTS; i++) mc_present_record(&p, 2 + i * .01);
    mc_present_shown(&p, c, 3);
    mc_present_completed(&p, c, 3, .1, 0);
    assert(p.latestShown == b && mc_present_backlog(&p).gpu == MC_PRESENT_RECEIPTS);
    assert(mc_present_duration(MC_PRESENT_READY, 50, .030, .0417, 1) == 0);
    assert(mc_present_duration(MC_PRESENT_PRECISE, 50, .030, .0417, 1) == 0);
    assert(mc_present_duration(MC_PRESENT_DURATION, 50, .030, .0417, 1) == .020);
    assert(mc_present_duration(MC_PRESENT_ADAPTIVE, 120, .020, .0417, 0) == 1.0/120);
    assert(fabs(mc_present_duration(MC_PRESENT_ADAPTIVE, 120, .020, .0417, 1) - .021) < 1e-9);
    assert(mc_present_duration(MC_PRESENT_ADAPTIVE, 120, .100, .0417, 1) == .0417);
    assert(mc_present_duration(MC_PRESENT_ADAPTIVE, 30, .001, .025, 1) == 1.0/30);
    assert(mc_present_duration(MC_PRESENT_ADAPTIVE, 120, NAN, .0417, 1) == 1.0/120);
    assert(mc_present_wait_limit(120) == .025 && mc_present_wait_limit(30) == .050);
    puts("PASS: independent GPU/display backlog, missing and late notifications, bounded history, presentation durations");
}
