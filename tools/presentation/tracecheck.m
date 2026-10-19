// No windows or GPU calls: verify that a stuck main thread cannot hide its last stage.
#import "mcpresentationtrace.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, const char **argv) {
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "--disabled")) {
        mc_presentation_mark("disabled", NULL, 0);
        mc_presentation_trace_note("disabled");
        return mc_presentation_trace_enabled() ? 1 : 0;
    }
    int rc = mc_presentation_trace_open(argv[1]);
    if (rc) { fprintf(stderr,"open failed: %d\n",rc); return rc == -EEXIST ? 3 : 4; }
    mc_presentation_trace_note("test.transition.before");
    for (long i=0; i<300; i++) mc_presentation_mark("test.render", NULL, i);
    mc_presentation_mark("test.deliberately-stuck", NULL, 42);
    // The parent kills this process after reading the watchdog's flushed snapshot.
    for (;;) pause();
}
