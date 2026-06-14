/*
 * PoC: Maple Tree data race in ma_dead_node() / mte_set_node_dead()
 *
 * This triggers a KCSAN-reported data race between:
 *   - Writer: mmap(MAP_FIXED) replacing VMAs -> mte_set_node_dead() plain store to node->parent
 *   - Reader: page fault -> lock_vma_under_rcu() -> mtree_range_walk() -> ma_dead_node() plain load
 *
 * Two threads share the same mm_struct:
 *   Thread A (writer): rapidly mmap(MAP_FIXED) overlapping subranges to force VMA tree churn
 *   Thread B (reader): repeatedly madvise(MADV_DONTNEED) + touch pages to generate page faults
 *
 * On a KCSAN-enabled kernel, this produces:
 *   BUG: KCSAN: data-race in ... mte_set_node_dead / ma_dead_node
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <sys/types.h>
#include <pwd.h>

#define PAGE_SIZE       4096
/* Base region: 256 pages = 1MB */
#define REGION_PAGES    256
#define REGION_SIZE     (REGION_PAGES * PAGE_SIZE)
/* How many sub-mappings to create initially to build up the maple tree */
#define INITIAL_MAPS    64
/* Duration in seconds */
#define DURATION_SEC    15

static volatile int stop_flag = 0;
static void *region_base = NULL;

static void alarm_handler(int sig) {
    (void)sig;
    stop_flag = 1;
}

/*
 * Writer thread: repeatedly mmap(MAP_FIXED) overlapping sub-ranges inside
 * the region to force VMA splits/replacements in the maple tree.
 * This exercises: mmap -> mmap_region -> vms_gather_munmap_vmas / __split_vma
 * -> mas_wr_node_store -> mas_replace_node -> mte_set_node_dead()
 */
static void *writer_thread(void *arg) {
    (void)arg;
    unsigned long base = (unsigned long)region_base;
    int iter = 0;

    while (!stop_flag) {
        /* Phase 1: Create many small mappings to build up tree nodes */
        for (int i = 0; i < INITIAL_MAPS && !stop_flag; i++) {
            size_t offset = (i * 4) * PAGE_SIZE;
            if (offset + PAGE_SIZE > REGION_SIZE)
                break;
            void *addr = (void *)(base + offset);
            mmap(addr, PAGE_SIZE,
                 PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                 -1, 0);
        }

        /* Phase 2: Overlay with different-sized mappings to force splits */
        for (int i = 0; i < 32 && !stop_flag; i++) {
            size_t sz = ((i % 7) + 1) * PAGE_SIZE;
            size_t offset = ((i * 3) % (REGION_PAGES - 8)) * PAGE_SIZE;
            void *addr = (void *)(base + offset);
            mmap(addr, sz,
                 PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                 -1, 0);
        }

        /* Phase 3: Replace the whole region to cause mass node replacement */
        if ((iter % 4) == 0) {
            mmap(region_base, REGION_SIZE,
                 PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                 -1, 0);
        }

        iter++;
    }
    return NULL;
}

/*
 * Reader thread: repeatedly touch pages in the region to trigger page faults.
 * Each fault enters do_user_addr_fault() -> lock_vma_under_rcu() -> mas_walk()
 * -> mtree_range_walk() -> ma_dead_node() (the racy read side).
 *
 * We use madvise(MADV_DONTNEED) to discard the page, then re-touch it.
 */
static void *reader_thread(void *arg) {
    (void)arg;
    unsigned long base = (unsigned long)region_base;
    unsigned int seed = (unsigned int)time(NULL) ^ (unsigned int)pthread_self();

    while (!stop_flag) {
        for (int i = 0; i < REGION_PAGES && !stop_flag; i++) {
            int page_idx = (i * 7 + (seed & 0xff)) % REGION_PAGES;
            void *addr = (void *)(base + page_idx * PAGE_SIZE);

            /* Discard the page to force a future fault */
            madvise(addr, PAGE_SIZE, MADV_DONTNEED);

            /* Touch the page to trigger a page fault */
            volatile char *p = (volatile char *)addr;
            *p = 0x42;
        }
        seed++;
    }
    return NULL;
}

static void sigsegv_handler(int sig, siginfo_t *info, void *ctx) {
    (void)sig;
    (void)info;
    ucontext_t *uc = (ucontext_t *)ctx;
#ifdef __x86_64__
    uc->uc_mcontext.gregs[REG_RIP] += 3;
#elif defined(__i386__)
    uc->uc_mcontext.gregs[REG_EIP] += 3;
#endif
}

int main(void) {
    int num_readers = 2;
    int num_writers = 2;

    /* Drop privileges if running as root */
    if (getuid() == 0) {
        /* Try to drop to uid 1000 */
        if (setgid(1000) == 0 && setuid(1000) == 0) {
            printf("[*] Dropped privileges to uid=%d gid=%d\n", getuid(), getgid());
        } else {
            printf("[!] Warning: failed to drop privileges: %s\n", strerror(errno));
            /* Continue anyway - the race is still valid */
        }
    }

    printf("[*] Running as uid=%d gid=%d\n", getuid(), getgid());
    fflush(stdout);

    printf("[*] Maple tree data race PoC\n");
    printf("[*] Duration: %d seconds\n", DURATION_SEC);
    printf("[*] Writers: %d, Readers: %d\n", num_writers, num_readers);

    /* Install SIGSEGV handler so reader threads don't die */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = sigsegv_handler;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);

    /* Set up alarm to stop after DURATION_SEC */
    signal(SIGALRM, alarm_handler);
    alarm(DURATION_SEC);

    /* Create the initial mapping region */
    region_base = mmap(NULL, REGION_SIZE,
                       PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS,
                       -1, 0);
    if (region_base == MAP_FAILED) {
        perror("mmap initial region");
        return 1;
    }
    printf("[*] Region base: %p, size: 0x%lx\n",
           region_base, (unsigned long)REGION_SIZE);

    /* Fault in all pages initially */
    memset(region_base, 0, REGION_SIZE);

    /* Create threads */
    pthread_t threads[16];
    int tidx = 0;

    for (int i = 0; i < num_writers; i++) {
        if (pthread_create(&threads[tidx++], NULL, writer_thread, NULL)) {
            perror("pthread_create writer");
            return 1;
        }
    }

    for (int i = 0; i < num_readers; i++) {
        if (pthread_create(&threads[tidx++], NULL, reader_thread, NULL)) {
            perror("pthread_create reader");
            return 1;
        }
    }

    printf("[*] Threads running, waiting for %d seconds...\n", DURATION_SEC);
    printf("[*] Check dmesg for KCSAN data-race reports on maple_tree\n");

    /* Wait for threads */
    for (int i = 0; i < tidx; i++) {
        pthread_join(threads[i], NULL);
    }

    printf("[*] Done. Checking dmesg for data race reports...\n");

    /* Try to print any KCSAN reports */
    fflush(stdout);
    system("dmesg | grep -A 20 'BUG: KCSAN' 2>/dev/null || "
           "dmesg | grep -i -A 5 'data-race' 2>/dev/null || "
           "echo '[*] No KCSAN reports found in dmesg (may need KCSAN kernel)'");

    return 0;
}
