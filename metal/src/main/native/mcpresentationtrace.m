#import "mcpresentationtrace.h"
#import <QuartzCore/QuartzCore.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

// One unique file per process. Never truncate yesterday's crash evidence. Full storage
// flushes are restricted to transitions/stalls, not frames or GPU completion callbacks.
static atomic_bool enabled;
static int traceFd = -1;
static pthread_mutex_t ringLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t fileLock = PTHREAD_MUTEX_INITIALIZER;
static unsigned long sequence;
static double lastProgress;
#define RECORDS 128
typedef struct {
    unsigned long sequence;
    double time;
    uintptr_t object;
    long value;
    char stage[80];
} Record;
static Record ring[RECORDS];

int mc_presentation_trace_enabled(void) { return atomic_load(&enabled); }

void mc_presentation_mark(const char *stage, const void *object, long value) {
    if (!atomic_load(&enabled)) return;
    pthread_mutex_lock(&ringLock);
    unsigned long seq = ++sequence;
    Record *r = &ring[(seq - 1) % RECORDS];
    *r = (Record){.sequence=seq, .time=CACurrentMediaTime(), .object=(uintptr_t)object, .value=value};
    strlcpy(r->stage, stage, sizeof(r->stage));
    lastProgress = r->time;
    pthread_mutex_unlock(&ringLock);
}

static void writeAll(const char *s) {
    size_t left = strlen(s);
    while (left) {
        ssize_t n = write(traceFd, s, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            fprintf(stderr, "[mcopt] presentation trace write failed: %s\n", strerror(errno));
            atomic_store(&enabled, false);
            return;
        }
        s += n; left -= n;
    }
}

static void persist(void) {
    // fsync alone can leave data in a drive's volatile cache. F_FULLFSYNC requests
    // storage persistence; this is best effort, not a guarantee against power loss.
    int rc;
    do { rc = fcntl(traceFd, F_FULLFSYNC); } while (rc < 0 && errno == EINTR);
    if (rc < 0) {
        int fullError = errno;
        do { rc = fsync(traceFd); } while (rc < 0 && errno == EINTR);
        char line[256];
        snprintf(line, sizeof(line), "sync-warning fullsync_errno=%d fsync_result=%d errno=%d\n", fullError, rc, rc < 0 ? errno : 0);
        writeAll(line);
        fprintf(stderr, "[mcopt] presentation trace: %s", line);
    }
}

static void stamp(const char *message) {
    struct timeval wall; gettimeofday(&wall, NULL);
    char line[2048];
    snprintf(line, sizeof(line), "wall=%lld.%06d mono=%.6f %s\n", (long long)wall.tv_sec,
        (int)wall.tv_usec, CACurrentMediaTime(), message);
    writeAll(line);
}

void mc_presentation_trace_note(const char *message) {
    if (!atomic_load(&enabled)) return;
    pthread_mutex_lock(&fileLock);
    stamp(message);
    persist();
    pthread_mutex_unlock(&fileLock);
}

void mc_presentation_checkpoint(NSString *message) { mc_presentation_trace_note(message.UTF8String); }

static void dumpRecords(const char *reason, const Record *recent, unsigned long seq) {
    pthread_mutex_lock(&fileLock);
    stamp(reason);
    unsigned long first = seq > RECORDS ? seq - RECORDS + 1 : 1;
    for (unsigned long i = first; i <= seq; i++) {
        const Record *r = &recent[(i - 1) % RECORDS];
        char line[256];
        snprintf(line, sizeof(line), "seq=%lu mono=%.6f stage=%s object=0x%llx value=%ld\n",
            r->sequence, r->time, r->stage, (unsigned long long)r->object, r->value);
        writeAll(line);
    }
    persist();
    pthread_mutex_unlock(&fileLock);
}

void mc_presentation_snapshot(const char *reason) {
    if (!atomic_load(&enabled)) return;
    Record recent[RECORDS];
    pthread_mutex_lock(&ringLock);
    unsigned long seq = sequence;
    memcpy(recent, ring, sizeof(recent));
    pthread_mutex_unlock(&ringLock);
    dumpRecords(reason, recent, seq);
}

static void *watchProgress(void *unused) {
    unsigned long reported = 0;
    while (atomic_load(&enabled)) {
        usleep(250000);
        Record recent[RECORDS];
        unsigned long seq; double last;
        pthread_mutex_lock(&ringLock);
        seq = sequence; last = lastProgress;
        if (!seq || seq == reported || CACurrentMediaTime() - last < 1.0) {
            pthread_mutex_unlock(&ringLock); continue;
        }
        memcpy(recent, ring, sizeof(recent));
        pthread_mutex_unlock(&ringLock);
        reported = seq;
        // No Metal/AppKit calls here: inspecting a stalled driver could block this
        // thread too. These are CPU breadcrumbs, not a claim that the GPU hung.
        dumpRecords("STALL: no render-thread progress for >=1s; recent stages follow (loading/idle can also cause this)", recent, seq);
    }
    return NULL;
}

int mc_presentation_trace_open(const char *path) {
    if (traceFd >= 0) return -EALREADY;
    traceFd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (traceFd < 0) return -errno;
    atomic_store(&enabled, true);
    mc_presentation_trace_note("trace-open schema=1; transition records use F_FULLFSYNC; frame stages stay in memory until a stall or link close");
    if (!atomic_load(&enabled)) { close(traceFd); traceFd = -1; return -EIO; }
    pthread_t watcher;
    int error = pthread_create(&watcher, NULL, watchProgress, NULL);
    if (error) {
        atomic_store(&enabled, false); close(traceFd); traceFd = -1; return -error;
    }
    pthread_detach(watcher); // process lifetime; never holds a drawable or calls the driver
    return 0;
}

void mc_presentation_trace_java(int stage, long object, long value) {
    const char *name;
    switch (stage) {
        case 0: name = "java.before-input"; break;
        case 1: name = "java.after-display-wait"; break;
        case 2: name = "legacy.nextDrawable.begin"; break;
        case 3: name = "legacy.nextDrawable.end"; break;
        default: name = "java.unknown"; break;
    }
    mc_presentation_mark(name, (void *)object, value);
}
