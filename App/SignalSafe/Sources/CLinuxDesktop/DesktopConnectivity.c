#include "CLinuxDesktop.h"
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <string.h>
#include <time.h>

// Hash assigned addresses as well as interface names so moving between two
// networks using the same Wi-Fi device triggers a reconnect.
static uint64_t hash_bytes(uint64_t hash, const unsigned char *bytes, size_t length) {
    for (size_t i = 0; i < length; i++) hash = (hash ^ bytes[i]) * UINT64_C(1099511628211);
    return hash;
}

uint64_t serein_network_signature(void) {
    struct ifaddrs *interfaces;
    if (getifaddrs(&interfaces) != 0) return 0;
    uint64_t signature = 0;
    for (struct ifaddrs *it = interfaces; it; it = it->ifa_next) {
        if (!it->ifa_addr || !(it->ifa_flags & IFF_UP) || !(it->ifa_flags & IFF_RUNNING) || (it->ifa_flags & IFF_LOOPBACK)) continue;
        const unsigned char *bytes;
        size_t size;
        if (it->ifa_addr->sa_family == AF_INET) {
            bytes = (const unsigned char *)&((struct sockaddr_in *)it->ifa_addr)->sin_addr;
            size = sizeof(struct in_addr);
        } else if (it->ifa_addr->sa_family == AF_INET6) {
            bytes = (const unsigned char *)&((struct sockaddr_in6 *)it->ifa_addr)->sin6_addr;
            size = sizeof(struct in6_addr);
        } else continue;
        uint64_t name = hash_bytes(UINT64_C(14695981039346656037), (const unsigned char *)it->ifa_name, strlen(it->ifa_name));
        signature += hash_bytes(name, bytes, size);
    }
    freeifaddrs(interfaces);
    return signature;
}

int64_t serein_suspended_milliseconds(void) {
    struct timespec boot, awake;
    if (clock_gettime(CLOCK_BOOTTIME, &boot) || clock_gettime(CLOCK_MONOTONIC, &awake)) return 0;
    return (boot.tv_sec - awake.tv_sec) * INT64_C(1000) + (boot.tv_nsec - awake.tv_nsec) / 1000000;
}
