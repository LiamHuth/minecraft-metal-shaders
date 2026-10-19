// Diagnostic-only flight recorder. Stage markers never perform file I/O or call Metal.
#import <Foundation/Foundation.h>
int mc_presentation_trace_open(const char *path);
int mc_presentation_trace_enabled(void);
void mc_presentation_mark(const char *stage, const void *object, long value);
void mc_presentation_snapshot(const char *reason);
void mc_presentation_checkpoint(NSString *message);
// Java entry points (string copied during the call; no Java memory retained).
void mc_presentation_trace_note(const char *message);
void mc_presentation_trace_java(int stage, long object, long value);
