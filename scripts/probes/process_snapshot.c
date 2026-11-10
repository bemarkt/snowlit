// macOS host observation only. No task ports, argv, environment, or process signals.
#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <unistd.h>

typedef struct {
    struct proc_bsdinfo identity;
    struct proc_taskinfo metrics;
    bool candidate;
    bool selected;
    const char *measurement;
} Observation;

static int fail(const char *phase, int pid, int code) {
    // Fixed diagnostic fields; never include unrelated process content.
    fprintf(stderr, "{\"phase\":\"%s\",\"pid\":%d,\"errorCode\":%d}\n", phase, pid, code);
    return 1;
}

static const char *name_of(const struct proc_bsdinfo *info) {
    return info->pbi_name[0] ? info->pbi_name : info->pbi_comm;
}

static bool is_candidate(const char *name) {
    const size_t length = strlen(name);
    return strncmp(name, "com.apple.WebKit.", 17) == 0 ||
        strcmp(name, "WebContent") == 0 || strcmp(name, "xctest") == 0 ||
        strcmp(name, "Snowlit") == 0 ||
        (length >= 7 && strcmp(name + length - 7, "-Runner") == 0);
}

static void print_string(const char *value) {
    putchar('"');
    for (const unsigned char *c = (const unsigned char *)value; *c; ++c) {
        if (*c == '"' || *c == '\\') { putchar('\\'); putchar(*c); }
        else if (*c < 32 || *c >= 127) printf("\\u%04x", *c);
        else putchar(*c);
    }
    putchar('"');
}

int main(int argc, char **argv) {
    const bool include_self = argc == 2 && strcmp(argv[1], "--self") == 0;
    if (argc != 1 && !include_self) return fail("arguments", 0, EINVAL);
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom)
        return fail("timebase", 0, EINVAL);
    int *pids = NULL;
    int count = 0;
    bool complete = false;
    for (int attempt = 0; attempt < 3; ++attempt) {
        // Simulator processes run as this host user. Other users' tasks are
        // outside this measurement scope; no elevation or task-port access.
        int estimate = proc_listpids(PROC_UID_ONLY, getuid(), NULL, 0);
        if (estimate <= 0 || estimate > 4000000) return fail("list-size", 0, errno);
        const int capacity = estimate / (int)sizeof(*pids) + 256;
        free(pids);
        pids = calloc((size_t)capacity, sizeof(*pids));
        if (!pids) return fail("allocate", 0, ENOMEM);
        int bytes = proc_listpids(PROC_UID_ONLY, getuid(), pids, capacity * (int)sizeof(*pids));
        if (bytes <= 0 || bytes % (int)sizeof(*pids) != 0) return fail("list", 0, errno);
        count = bytes / (int)sizeof(*pids);
        if (count < capacity) { complete = true; break; }
    }
    if (!complete) return fail("list-truncated", 0, EOVERFLOW);
    Observation *observations = calloc((size_t)count, sizeof(*observations));
    if (!observations) return fail("allocate", 0, ENOMEM);
    int used = 0;
    int exited_during_discovery = 0;
    for (int i = 0; i < count; ++i) {
        if (pids[i] <= 0) continue;
        struct proc_bsdinfo info = {0};
        errno = 0;
        int received = proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info));
        if (received != (int)sizeof(info)) {
            if (received == 0 && errno == ESRCH) { ++exited_during_discovery; continue; }
            return fail("identity", pids[i], errno);
        }
        info.pbi_name[sizeof(info.pbi_name) - 1] = '\0';
        info.pbi_comm[sizeof(info.pbi_comm) - 1] = '\0';
        Observation *entry = &observations[used++];
        entry->identity = info;
        entry->candidate = is_candidate(name_of(&info)) || (include_self && pids[i] == getpid());
        entry->selected = entry->candidate;
        entry->measurement = "identity-only";
    }
    for (int i = 0; i < used; ++i) {
        if (!observations[i].candidate) continue;
        uint32_t parent = observations[i].identity.pbi_ppid;
        for (int depth = 0; depth < used && parent; ++depth) {
            int found = -1;
            for (int j = 0; j < used; ++j) {
                if (observations[j].identity.pbi_pid == parent) { found = j; break; }
            }
            if (found < 0 || observations[found].selected) break;
            observations[found].selected = true;
            parent = observations[found].identity.pbi_ppid;
        }
        struct proc_taskallinfo info = {0};
        errno = 0;
        int received = proc_pidinfo((int)observations[i].identity.pbi_pid,
                                    PROC_PIDTASKALLINFO, 0, &info, sizeof(info));
        if (received != (int)sizeof(info)) {
            if (received == 0 && errno == ESRCH) {
                observations[i].measurement = "exited-during-sample";
                continue;
            }
            return fail("metrics", (int)observations[i].identity.pbi_pid, errno);
        }
        const struct proc_bsdinfo *before = &observations[i].identity;
        if (before->pbi_pid != info.pbsd.pbi_pid ||
            before->pbi_start_tvsec != info.pbsd.pbi_start_tvsec ||
            before->pbi_start_tvusec != info.pbsd.pbi_start_tvusec) {
            observations[i].measurement = "identity-changed-during-sample";
            continue;
        }
        observations[i].metrics = info.ptinfo;
        observations[i].measurement = "measured";
    }
    printf("{\"samplerPID\":%d,\"hostUID\":%u,\"exitedDuringDiscovery\":%d,"
           "\"timebaseNumerator\":%u,\"timebaseDenominator\":%u,\"processes\":[",
           getpid(), getuid(), exited_during_discovery, timebase.numer, timebase.denom);
    bool comma = false;
    for (int i = 0; i < used; ++i) {
        const Observation *entry = &observations[i];
        if (!entry->selected) continue;
        const struct proc_bsdinfo *info = &entry->identity;
        if (comma) putchar(',');
        comma = true;
        printf("{\"pid\":%u,\"parentPID\":%u,\"startSeconds\":%" PRIu64
               ",\"startMicroseconds\":%" PRIu64 ",\"candidate\":%s,\"executable\":",
               info->pbi_pid, info->pbi_ppid, info->pbi_start_tvsec, info->pbi_start_tvusec,
               entry->candidate ? "true" : "false");
        print_string(name_of(info));
        printf(",\"measurement\":\"%s\"", entry->measurement);
        if (strcmp(entry->measurement, "measured") == 0) {
            printf(",\"rssBytes\":%" PRIu64 ",\"userTicks\":%" PRIu64
                   ",\"systemTicks\":%" PRIu64,
                   entry->metrics.pti_resident_size, entry->metrics.pti_total_user,
                   entry->metrics.pti_total_system);
        }
        putchar('}');
    }
    puts("]}");
    free(observations);
    free(pids);
    return 0;
}
