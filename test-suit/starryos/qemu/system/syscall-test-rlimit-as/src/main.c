/*
 * syscall-test-rlimit-as — RLIMIT_AS enforcement on mmap(2) / mremap(2).
 *
 * The general prlimit64 suite (syscall-test-prlimit64) covers RLIMIT_AS at the
 * query+consistency layer only; the browser-prerequisite checklist calls out
 * that the *enforcement* path (WASM/V8 grow their address space via mmap) was
 * never asserted. This test adds it, mirroring Linux `may_expand_vm()`
 * (mm/mmap.c): a mapping is rejected with ENOMEM when
 *   mm->total_vm + npages > rlimit(RLIMIT_AS) >> PAGE_SHIFT
 * and mremap growth is charged its delta the same way (mm/mremap.c). RLIM_INFINITY
 * disables the cap.
 *
 * Assertions are baseline-free where possible (a single mapping larger than the
 * whole soft limit must fail no matter the current usage); the precise-boundary
 * sub-case is gated on /proc/self/statm being readable so it degrades cleanly.
 */
#define _GNU_SOURCE
#include "test_framework.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>

#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS 0x20
#endif

/* Address space size in bytes from /proc/self/statm field 0 (pages). 0 if N/A. */
static size_t read_vmsize(void)
{
    int fd = open("/proc/self/statm", O_RDONLY);
    if (fd < 0) {
        return 0;
    }
    char buf[128] = {0};
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) {
        return 0;
    }
    unsigned long pages = strtoul(buf, NULL, 10);
    return (size_t)pages * (size_t)sysconf(_SC_PAGESIZE);
}

static int set_as(rlim_t cur, rlim_t max)
{
    struct rlimit rl = {.rlim_cur = cur, .rlim_max = max};
    return setrlimit(RLIMIT_AS, &rl);
}

int main(void)
{
    TEST_START("RLIMIT_AS enforcement (mmap/mremap address-space cap)");
    const size_t PAGE = (size_t)sysconf(_SC_PAGESIZE);
    const size_t MB = 1024UL * 1024UL;
    const int mf = MAP_PRIVATE | MAP_ANONYMOUS;
    const struct rlimit inf = {RLIM_INFINITY, RLIM_INFINITY};

    /* --- A. query --- */
    struct rlimit def;
    CHECK_RET(getrlimit(RLIMIT_AS, &def), 0, "getrlimit(RLIMIT_AS) succeeds");
    printf("  default RLIMIT_AS cur=%llu max=%llu\n", (unsigned long long)def.rlim_cur,
           (unsigned long long)def.rlim_max);

    /* --- B. a single mapping larger than the whole soft limit fails ENOMEM
     *        (baseline-free: 512MB > 16MB regardless of current usage) --- */
    CHECK_RET(set_as(16 * MB, def.rlim_max), 0, "setrlimit(RLIMIT_AS, 16MB soft) succeeds");
    {
        void *p = mmap(NULL, 512 * MB, PROT_NONE, mf, -1, 0);
        CHECK(p == MAP_FAILED && errno == ENOMEM,
              "mmap(512MB) with 16MB RLIMIT_AS fails ENOMEM (single mapping exceeds cap)");
        if (p != MAP_FAILED) {
            munmap(p, 512 * MB);
        }
    }

    /* --- C. RLIM_INFINITY disables the cap: same reservation now succeeds --- */
    CHECK_RET(setrlimit(RLIMIT_AS, &inf), 0, "setrlimit(RLIMIT_AS, RLIM_INFINITY) succeeds");
    {
        void *p = mmap(NULL, 512 * MB, PROT_NONE, mf, -1, 0);
        CHECK(p != MAP_FAILED, "mmap(512MB) succeeds under RLIM_INFINITY (no cap)");
        if (p != MAP_FAILED) {
            munmap(p, 512 * MB);
        }
    }

    /* --- D. generous finite limit above baseline: a small mmap succeeds --- */
    CHECK_RET(set_as(512 * MB, RLIM_INFINITY), 0, "setrlimit(RLIMIT_AS, 512MB soft) succeeds");
    {
        void *p = mmap(NULL, 8 * MB, PROT_NONE, mf, -1, 0);
        CHECK(p != MAP_FAILED, "mmap(8MB) succeeds within 512MB RLIMIT_AS");
        if (p != MAP_FAILED) {
            munmap(p, 8 * MB);
        }
    }

    /* --- E. precise boundary via /proc/self/statm (comfortable 32MB headroom) --- */
    size_t vm = read_vmsize();
    if (vm > 0) {
        printf("  current VmSize=%zu bytes (~%zu MB)\n", vm, vm / MB);
        CHECK_RET(set_as((rlim_t)(vm + 32 * MB), RLIM_INFINITY), 0,
                  "setrlimit(RLIMIT_AS, VmSize+32MB) succeeds");
        {
            void *p = mmap(NULL, 8 * MB, PROT_NONE, mf, -1, 0);
            CHECK(p != MAP_FAILED, "mmap(8MB) within 32MB headroom succeeds");
            if (p != MAP_FAILED) {
                munmap(p, 8 * MB);
            }
        }
        {
            void *p = mmap(NULL, 128 * MB, PROT_NONE, mf, -1, 0);
            CHECK(p == MAP_FAILED && errno == ENOMEM,
                  "mmap(128MB) beyond 32MB headroom fails ENOMEM");
            if (p != MAP_FAILED) {
                munmap(p, 128 * MB);
            }
        }
        (void)PAGE;
    } else {
        printf("  NOTE: /proc/self/statm unavailable, skipping precise-boundary sub-case\n");
    }

    /* --- F. mremap growth is charged its delta; shrink/move within cap is not --- */
    CHECK_RET(setrlimit(RLIMIT_AS, &inf), 0, "restore RLIM_INFINITY before mremap setup");
    {
        size_t old = 4 * MB;
        void *base = mmap(NULL, old, PROT_READ | PROT_WRITE, mf, -1, 0);
        CHECK(base != MAP_FAILED, "mmap(4MB) base for mremap succeeds");
        if (base != MAP_FAILED) {
            CHECK_RET(set_as(16 * MB, RLIM_INFINITY), 0,
                      "setrlimit(RLIMIT_AS, 16MB) for mremap-grow test");
            /* delta 252MB >> 16MB cap regardless of baseline */
            void *g = mremap(base, old, 256 * MB, MREMAP_MAYMOVE);
            CHECK(g == MAP_FAILED && errno == ENOMEM,
                  "mremap grow 4MB->256MB fails ENOMEM (growth delta exceeds RLIMIT_AS)");
            void *cur = (g == MAP_FAILED) ? base : g;
            size_t cur_size = (g == MAP_FAILED) ? old : 256 * MB;
            CHECK_RET(setrlimit(RLIMIT_AS, &inf), 0, "restore RLIM_INFINITY after grow-fail");
            void *g2 = mremap(cur, cur_size, cur_size + 2 * MB, MREMAP_MAYMOVE);
            CHECK(g2 != MAP_FAILED, "mremap small grow succeeds under RLIM_INFINITY");
            if (g2 != MAP_FAILED) {
                munmap(g2, cur_size + 2 * MB);
            } else {
                munmap(cur, cur_size);
            }
        }
    }

    setrlimit(RLIMIT_AS, &def);
    TEST_DONE();
}
