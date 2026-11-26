#include "CLinuxCallNetwork.h"
#include "Broker.h"
#include <arpa/inet.h>
#include <gio/gio.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <netpacket/packet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int call_net_parse_ip(const uint8_t *text, size_t n, uint8_t *ip, size_t k) {
    if (!text || !n || n >= INET6_ADDRSTRLEN || memchr(text, 0, n) || !ip || k < 16) return 0;
    char address[INET6_ADDRSTRLEN] = {0};
    memcpy(address, text, n);
    if (inet_pton(AF_INET, address, ip) == 1) return 4;
    return inet_pton(AF_INET6, address, ip) == 1 ? 16 : 0;
}
int call_net_format_ip(const uint8_t *ip, size_t n, uint8_t *text, size_t k) {
    if (!ip || (n != 4 && n != 16) || !text || k < INET6_ADDRSTRLEN) return 0;
    return inet_ntop(n == 4 ? AF_INET : AF_INET6, ip, (char *)text, INET6_ADDRSTRLEN) ? (int)strlen((char *)text) : 0;
}
// Ask the routing table for a source address. Connecting a UDP socket only
// selects a route in the kernel. No data is transmitted.
static void route_source(int family, char *source, size_t n) {
    int fd = socket(family, SOCK_DGRAM | SOCK_CLOEXEC, IPPROTO_UDP);
    if (fd < 0) return;
    struct sockaddr_storage remote = {0}, local = {0};
    socklen_t len;
    if (family == AF_INET) {
        struct sockaddr_in *r = (void *)&remote;
        r->sin_family = AF_INET; r->sin_port = htons(9);
        inet_pton(family, "192.0.2.1", &r->sin_addr);
        len = sizeof(*r);
    } else {
        struct sockaddr_in6 *r = (void *)&remote;
        r->sin6_family = AF_INET6; r->sin6_port = htons(9);
        inet_pton(family, "2001:db8::1", &r->sin6_addr);
        len = sizeof(*r);
    }
    if (connect(fd, (struct sockaddr *)&remote, len) == 0 &&
        getsockname(fd, (struct sockaddr *)&local, &len) == 0) {
        const void *ip = family == AF_INET ? (void *)&((struct sockaddr_in *)&local)->sin_addr :
                                            (void *)&((struct sockaddr_in6 *)&local)->sin6_addr;
        inet_ntop(family, ip, source, n);
    }
    close(fd);
}

int call_net_local_interfaces(uint8_t *result, size_t n) {
    struct ifaddrs *interfaces;
    if (getifaddrs(&interfaces) < 0) return -1;
    g_autoptr(GString) list = g_string_new(NULL);
    char route4[INET_ADDRSTRLEN] = "", route6[INET6_ADDRSTRLEN] = "";
    route_source(AF_INET, route4, sizeof(route4));
    route_source(AF_INET6, route6, sizeof(route6));
    for (struct ifaddrs *i = interfaces; i; i = i->ifa_next) {
        if (!i->ifa_addr || !(i->ifa_flags & IFF_UP) || !(i->ifa_flags & IFF_RUNNING)) continue;
        int family = i->ifa_addr->sa_family;
        if (family != AF_INET && family != AF_INET6) continue;
        const void *ip = family == AF_INET ? (void *)&((struct sockaddr_in *)i->ifa_addr)->sin_addr :
                                             (void *)&((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr;
        char address[INET6_ADDRSTRLEN];
        if (!inet_ntop(family, ip, address, sizeof(address)) || strpbrk(i->ifa_name, "\t\n/")) continue;
        const char *name = i->ifa_name;
        g_autofree char *wireless = g_build_filename("/sys/class/net", name, "wireless", NULL);
        int ethernet = 0;
        for (struct ifaddrs *link = interfaces; link; link = link->ifa_next) {
            if (link->ifa_addr && link->ifa_addr->sa_family == AF_PACKET && !strcmp(link->ifa_name, name)) {
                ethernet = ((struct sockaddr_ll *)link->ifa_addr)->sll_hatype == ARPHRD_ETHER;
                break;
            }
        }
        const char *kind = "other";
        if (i->ifa_flags & IFF_LOOPBACK) kind = "loopback";
        else if (g_str_has_prefix(name, "tun") || g_str_has_prefix(name, "wg") || g_str_has_prefix(name, "ppp")) kind = "vpn";
        else if (g_file_test(wireless, G_FILE_TEST_IS_DIR)) kind = "wifi";
        else if (g_str_has_prefix(name, "wwan") || g_str_has_prefix(name, "rmnet")) kind = "cellular";
        else if (ethernet) kind = "ethernet";
        int routed = strcmp(address, family == AF_INET ? route4 : route6) == 0;
        g_string_append_printf(list, "%s\t%s\t%s\t%d\n", name, address, kind, routed);
    }
    freeifaddrs(interfaces);
    if (list->len > 1024 * 1024) return -1;
    if (result && list->len <= n) memcpy(result, list->str, list->len);
    return (int)list->len;
}

int call_net_interfaces(uint8_t *result, size_t n) {
    return call_broker_active() ? call_broker_interfaces(result, n) : call_net_local_interfaces(result, n);
}
