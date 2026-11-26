#define _GNU_SOURCE
#include "CLinuxDesktop.h"
#include <fcntl.h>
#include <linux/openat2.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

int serein_open_dropped_document(const uint8_t *path, size_t size, int64_t limit) {
    // Another application supplies the URI list. Read only a document-portal
    // grant, so a drag cannot select our private database, keys or session IPC.
    static const char directory[] = "/run/serein/doc/";
    if (size <= sizeof(directory) - 1 || size >= 4096 || limit < 0
        || memcmp(path, directory, sizeof(directory) - 1) || memchr(path, 0, size)) return -1;
    char relative[4096];
    size_t length = size - (sizeof(directory) - 1);
    memcpy(relative, path + sizeof(directory) - 1, length);
    relative[length] = 0;
    int root = open("/run/serein/doc", O_PATH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (root < 0) return -1;
    struct open_how how = {.flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOCTTY,
                           .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV};
    int fd = (int)syscall(SYS_openat2, root, relative, &how, sizeof(how));
    close(root);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size <= limit) return fd;
    close(fd);
    return -1;
}
