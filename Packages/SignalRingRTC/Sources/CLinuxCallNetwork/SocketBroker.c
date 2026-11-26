// Only this process resolves relay names, reserves UDP ports and dials peers.
// The calling engine receives connected sockets for media and performs TLS itself.
#define _GNU_SOURCE
#include "Broker.h"
#include "CLinuxCallNetwork.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <linux/rtnetlink.h>
#include <net/if.h>
#include <netpacket/packet.h>
#include <stdio.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <spawn.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

enum { broker_fd = 3, max_jobs = 32, max_leases = 64, interface_limit = 32768 };
static int route = -1;
static pid_t broker_pid = -1;
static pthread_mutex_t request_lock = PTHREAD_MUTEX_INITIALIZER;
struct Lease { uint16_t port; int fd, control; };
static struct Lease leases[max_leases];
static pthread_mutex_t lease_lock = PTHREAD_MUTEX_INITIALIZER;

static int send_fd(int channel, int fd) {
    char byte = fd >= 0;
    if (fd < 0) return send(channel, &byte, 1, MSG_NOSIGNAL) == 1;
    struct iovec iov = {&byte, 1};
    union { struct cmsghdr align; char data[CMSG_SPACE(sizeof(int))]; } c = {0};
    struct msghdr m = {.msg_iov=&iov, .msg_iovlen=1, .msg_control=c.data, .msg_controllen=sizeof(c.data)};
    struct cmsghdr *h = CMSG_FIRSTHDR(&m);
    h->cmsg_level = SOL_SOCKET; h->cmsg_type = SCM_RIGHTS; h->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(h), &fd, sizeof(fd));
    return sendmsg(channel, &m, MSG_NOSIGNAL) == 1;
}
static int receive_fd(int channel) {
    char byte = 0;
    struct iovec iov = {&byte, 1};
    union { struct cmsghdr align; char data[CMSG_SPACE(sizeof(int))]; } c;
    struct msghdr m = {.msg_iov=&iov, .msg_iovlen=1, .msg_control=c.data, .msg_controllen=sizeof(c.data)};
    ssize_t n;
    do { n = recvmsg(channel, &m, MSG_CMSG_CLOEXEC); } while (n < 0 && errno == EINTR);
    if (n != 1) return -1;
    int fd = -1;
    for (struct cmsghdr *h = CMSG_FIRSTHDR(&m); h; h = CMSG_NXTHDR(&m, h)) {
        if (h->cmsg_level != SOL_SOCKET || h->cmsg_type != SCM_RIGHTS) continue;
        size_t count = (h->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t i = 0; i < count; ++i) {
            int next; memcpy(&next, CMSG_DATA(h) + i * sizeof(int), sizeof(int));
            if (count == 1 && fd < 0 && byte == 1 && !(m.msg_flags & (MSG_TRUNC|MSG_CTRUNC))) fd = next;
            else close(next);
        }
    }
    return fd;
}
static int ready(int fd, short events, GCancellable *cancel, int ms) {
    GPollFD fds[2] = {{.fd=fd, .events=events}};
    int has_cancel = cancel && g_cancellable_make_pollfd(cancel, &fds[1]);
    int n;
    do { n = g_poll(fds, has_cancel ? 2 : 1, ms); } while (n < 0 && errno == EINTR);
    if (has_cancel) g_cancellable_release_fd(cancel);
    return n > 0 && (fds[0].revents & events) && !(cancel && g_cancellable_is_cancelled(cancel));
}
int call_broker_active(void) { return route >= 0; }
static void stop_broker(void) {
    if (route < 0) return;
    shutdown(route, SHUT_RDWR);
    close(route);
    while (waitpid(broker_pid, NULL, 0) < 0 && errno == EINTR) {}
}
int call_net_start_broker(void) {
    int pair[2];
    if (route >= 0 || socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair)) return 0;
    posix_spawn_file_actions_t actions;
    int initialized = !posix_spawn_file_actions_init(&actions);
    int ok = initialized && !posix_spawn_file_actions_adddup2(&actions, pair[1], broker_fd) &&
        !posix_spawn_file_actions_addclosefrom_np(&actions, broker_fd + 1);
    char *argv[] = {"SignalCallingService", "--linux-call-socket-broker", NULL};
    char *env[] = {"PATH=/usr/bin:/bin", "HOME=/nonexistent", "LANG=C",
                   "LD_LIBRARY_PATH=/usr/local/lib/serein/workers", NULL};
    pid_t pid = -1;
    ok = ok && !posix_spawn(&pid, "/proc/self/exe", &actions, NULL, argv, env);
    if (initialized) posix_spawn_file_actions_destroy(&actions);
    close(pair[1]);
    char ack;
    if (ok && ready(pair[0], POLLIN, NULL, 5000) && recv(pair[0], &ack, 1, 0) == 1 && ack == 'R' && !atexit(stop_broker)) {
        broker_pid = pid;
        route = pair[0];
        return 1;
    }
    close(pair[0]);
    if (pid > 0) {
        kill(pid, SIGTERM);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
    }
    return 0;
}
// A private channel per operation lets a slow relay lookup run independently
// of ICE and cancellation. The worker never sends a descriptor to the broker.
static int request_channel(const struct CallSocketRequest *req) {
    pthread_mutex_lock(&request_lock);
    int ch = -1;
    if (route >= 0 && send(route, "N", 1, MSG_NOSIGNAL) == 1)
        ch = receive_fd(route);
    pthread_mutex_unlock(&request_lock);
    if (ch >= 0 && send(ch, req, sizeof(*req), MSG_NOSIGNAL) != sizeof(*req)) {
        close(ch);
        return -1;
    }
    return ch;
}
int call_broker_socket(const struct CallSocketRequest *req, GCancellable *cancel) {
    int ch = request_channel(req);
    if (ch < 0) return -1;
    int fd = ready(ch, POLLIN, cancel, 16000) ? receive_fd(ch) : -1;
    close(ch);
    return fd;
}
int call_broker_interfaces(uint8_t *result, size_t capacity) {
    const struct CallSocketRequest req = {.op=CallInterfaces};
    int ch = request_channel(&req);
    if (ch < 0) return -1;
    ssize_t n = recv(ch, result, capacity, MSG_TRUNC);
    close(ch);
    return n >= 0 && n <= interface_limit ? (int)n : -1;
}
int call_broker_listen(int reuse, GCancellable *cancel, int *lease_fd) {
    const struct CallSocketRequest req = {.op=CallListen, .reuse=reuse};
    int ch = request_channel(&req);
    if (ch < 0) return -1;
    int socket = ready(ch, POLLIN, cancel, 5000) ? receive_fd(ch) : -1;
    if (socket < 0) close(ch);
    else *lease_fd = ch;
    return socket;
}

// Ask the kernel about the final numeric destination, after DNS. Only unicast
// routes on non-loopback interfaces can be used. This also rejects this host's
// own LAN addresses, broadcast routes and addresses added since startup.
static int remote_route(const struct sockaddr *peer) {
    int af = peer->sa_family;
    const void *address;
    if (af == AF_INET) {
        const struct in_addr *ip = &((const struct sockaddr_in *)peer)->sin_addr;
        uint32_t bits = ntohl(ip->s_addr);
        if ((bits >> 24) == 0 || (bits >> 24) == 127 || bits >= 0xe0000000u) return 0;
        address = ip;
    } else if (af == AF_INET6) {
        const struct in6_addr *ip = &((const struct sockaddr_in6 *)peer)->sin6_addr;
        if (IN6_IS_ADDR_UNSPECIFIED(ip) || IN6_IS_ADDR_LOOPBACK(ip) || IN6_IS_ADDR_V4MAPPED(ip) ||
            IN6_IS_ADDR_V4COMPAT(ip) || IN6_IS_ADDR_MULTICAST(ip) || IN6_IS_ADDR_LINKLOCAL(ip)) return 0;
        address = ip;
    } else return 0;
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    if (fd < 0) return 0;
    struct { struct nlmsghdr h; struct rtmsg r; char attributes[RTA_SPACE(16)]; } q = {0};
    int bytes = af == AF_INET ? 4 : 16;
    q.h.nlmsg_type = RTM_GETROUTE; q.h.nlmsg_flags = NLM_F_REQUEST; q.h.nlmsg_seq = 1;
    q.r.rtm_family = af; q.r.rtm_dst_len = bytes * 8;
    struct rtattr *attr = (struct rtattr *)q.attributes;
    attr->rta_type = RTA_DST; attr->rta_len = RTA_LENGTH(bytes);
    memcpy(RTA_DATA(attr), address, bytes);
    q.h.nlmsg_len = NLMSG_LENGTH(sizeof(q.r)) + RTA_ALIGN(attr->rta_len);
    struct sockaddr_nl kernel = {.nl_family=AF_NETLINK};
    int ok = 0;
    if (sendto(fd, &q, q.h.nlmsg_len, 0, (void *)&kernel, sizeof(kernel)) == (ssize_t)q.h.nlmsg_len &&
        ready(fd, POLLIN, NULL, 1000)) {
        union { struct nlmsghdr align; char data[8192]; } reply;
        struct sockaddr_nl sender = {0}; socklen_t len = sizeof(sender);
        ssize_t n = recvfrom(fd, reply.data, sizeof(reply.data), MSG_TRUNC, (void *)&sender, &len);
        if (n >= 0 && n <= (ssize_t)sizeof(reply.data) && !sender.nl_pid) {
            for (struct nlmsghdr *h = &reply.align; NLMSG_OK(h, n); h = NLMSG_NEXT(h, n)) {
                if (h->nlmsg_seq != 1 || h->nlmsg_type != RTM_NEWROUTE || h->nlmsg_len < NLMSG_LENGTH(sizeof(struct rtmsg))) continue;
                const struct rtmsg *r = NLMSG_DATA(h);
                if (r->rtm_type != RTN_UNICAST) continue;
                int remain = RTM_PAYLOAD(h);
                for (struct rtattr *a = RTM_RTA(r); RTA_OK(a, remain); a = RTA_NEXT(a, remain)) {
                    if (a->rta_type == RTA_OIF && RTA_PAYLOAD(a) == sizeof(unsigned)) {
                        unsigned index; memcpy(&index, RTA_DATA(a), sizeof(index));
                        struct ifaddrs *ifs;
                        if (!getifaddrs(&ifs)) {
                            for (const struct ifaddrs *i = ifs; i; i = i->ifa_next)
                                if (i->ifa_addr && i->ifa_addr->sa_family == AF_PACKET &&
                                    ((const struct sockaddr_ll *)i->ifa_addr)->sll_ifindex == (int)index)
                                    ok = (i->ifa_flags & IFF_UP) && !(i->ifa_flags & IFF_LOOPBACK);
                            freeifaddrs(ifs);
                        }
                    }
                }
            }
        }
    }
    close(fd);
    return ok;
}

// The private reply channel remains open for the lifetime of the listener.
// A cancelled setup, a closed listener or a worker exit relinquishes the lease.
static void reap_leases_locked(void) {
    for (int i = 0; i < max_leases; ++i) {
        if (!leases[i].port) continue;
        struct pollfd control = {.fd=leases[i].control, .events=POLLIN};
        if (poll(&control, 1, 0) > 0 && control.revents) {
            close(leases[i].fd);
            close(leases[i].control);
            leases[i].port = 0;
        }
    }
}

static int reserve(int reuse, int channel) {
    for (int v = 0; v < 2; ++v) {
        int family = v ? AF_INET : AF_INET6;
        int fd = socket(family, SOCK_DGRAM | SOCK_CLOEXEC, IPPROTO_UDP);
        if (fd < 0) continue;
        int one = 1, zero = 0;
        if ((reuse && setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one))) ||
            (!v && (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(zero)) ||
                    setsockopt(fd, IPPROTO_IPV6, IPV6_RECVPKTINFO, &one, sizeof(one)))) ||
            (v && setsockopt(fd, IPPROTO_IP, IP_PKTINFO, &one, sizeof(one)))) { close(fd); continue; }
        struct sockaddr_storage addr = {.ss_family=family};
        socklen_t len = v ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
        if (bind(fd, (void *)&addr, len) || getsockname(fd, (void *)&addr, &len)) { close(fd); continue; }
        uint16_t port = ntohs(v ? ((struct sockaddr_in *)&addr)->sin_port : ((struct sockaddr_in6 *)&addr)->sin6_port);
        pthread_mutex_lock(&lease_lock);
        reap_leases_locked();
        int reserved = 0;
        for (int i = 0; i < max_leases; ++i) if (!leases[i].port) {
            int copy = fcntl(fd, F_DUPFD_CLOEXEC, 3);
            int control = fcntl(channel, F_DUPFD_CLOEXEC, 3);
            if (copy >= 0 && control >= 0) {
                leases[i] = (struct Lease){port, copy, control};
                reserved = 1;
            } else {
                if (copy >= 0) close(copy);
                if (control >= 0) close(control);
            }
            break;
        }
        pthread_mutex_unlock(&lease_lock);
        if (reserved) return fd;
        close(fd);
    }
    return -1;
}
static int bind_reserved(int fd, int af, const struct CallSocketRequest *req) {
    if (!req->local_port) return !req->source[0];
    struct sockaddr_storage local = {.ss_family=af};
    void *ip; socklen_t size;
    if (af == AF_INET) {
        struct sockaddr_in *s = (void *)&local; s->sin_port = htons(req->local_port); ip = &s->sin_addr; size = sizeof(*s);
    } else {
        struct sockaddr_in6 *s = (void *)&local; s->sin6_port = htons(req->local_port); ip = &s->sin6_addr; size = sizeof(*s);
    }
    if (req->source[0] && inet_pton(af, req->source, ip) != 1) return 0;
    int one = 1, ok = 0;
    pthread_mutex_lock(&lease_lock);
    reap_leases_locked();
    for (int i = 0; i < max_leases; ++i) if (leases[i].port == req->local_port) {
        ok = !setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) && !bind(fd, (void *)&local, size);
        break;
    }
    pthread_mutex_unlock(&lease_lock);
    return ok;
}
static int dial(const struct CallSocketRequest *req) {
    if (!req->port || !req->host[0] || req->host[sizeof(req->host)-1] || req->source[sizeof(req->source)-1] ||
        (req->family != 0 && req->family != 4 && req->family != 6)) return -1;
    const int udp = req->op == CallUDP;
    if (!udp && (req->local_port || req->source[0])) return -1;
    struct addrinfo hints = {.ai_family=req->family == 4 ? AF_INET : req->family == 6 ? AF_INET6 : AF_UNSPEC,
        .ai_socktype=udp ? SOCK_DGRAM : SOCK_STREAM, .ai_protocol=udp ? IPPROTO_UDP : IPPROTO_TCP, .ai_flags=AI_NUMERICSERV};
    char service[6]; snprintf(service, sizeof(service), "%u", req->port);
    struct addrinfo *list;
    if (getaddrinfo(req->host, service, &hints, &list)) return -1;
    int fd = -1;
    for (struct addrinfo *a = list; a; a = a->ai_next) {
        if (!remote_route(a->ai_addr)) continue;
        fd = socket(a->ai_family, a->ai_socktype | SOCK_NONBLOCK | SOCK_CLOEXEC, a->ai_protocol);
        if (fd < 0) continue;
        if (bind_reserved(fd, a->ai_family, req)) {
            int rc = connect(fd, a->ai_addr, a->ai_addrlen);
            if (rc < 0 && errno == EINPROGRESS && ready(fd, POLLOUT, NULL, 8000)) {
                int err = -1; socklen_t size = sizeof(err);
                if (!getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &size) && !err) rc = 0;
            }
            if (!rc) {
                if (!udp) { int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)); }
                break;
            }
        }
        close(fd); fd = -1;
    }
    freeaddrinfo(list);
    return fd;
}

static void serve_request(gpointer value, gpointer unused) {
    int ch = GPOINTER_TO_INT(value);
    struct CallSocketRequest req;
    if (ready(ch, POLLIN, NULL, 2000) && recv(ch, &req, sizeof(req), MSG_TRUNC) == sizeof(req)) {
        if (req.op == CallInterfaces) {
            uint8_t result[interface_limit];
            int n = call_net_local_interfaces(result, sizeof(result));
            if (n >= 0 && n <= interface_limit) send(ch, result, n, MSG_NOSIGNAL);
        } else {
            int fd = -1;
            if (req.op == CallListen) fd = reserve(req.reuse, ch);
            else if (req.op == CallTCP || req.op == CallUDP) fd = dial(&req);
            send_fd(ch, fd);
            if (fd >= 0) close(fd);
        }
    }
    close(ch);
    (void)unused;
}
int call_net_serve_broker(void) {
    // Peer is the private socket pair created before the worker installs its filter.
    struct sockaddr_storage peer; socklen_t len = sizeof(peer);
    if (getpeername(broker_fd, (void *)&peer, &len) || peer.ss_family != AF_UNIX) return 78;
    struct ucred credentials;
    len = sizeof(credentials);
    if (getsockopt(broker_fd, SOL_SOCKET, SO_PEERCRED, &credentials, &len) ||
        len != sizeof(credentials) || credentials.pid != getppid() || credentials.uid != geteuid()) return 78;
    GThreadPool *pool = g_thread_pool_new(serve_request, NULL, max_jobs, FALSE, NULL);
    if (!pool || send(broker_fd, "R", 1, MSG_NOSIGNAL) != 1) return 78;
    char byte;
    for (;;) {
        struct pollfd control = {.fd=broker_fd, .events=POLLIN};
        int n = poll(&control, 1, 1000);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return 1;
        pthread_mutex_lock(&lease_lock);
        reap_leases_locked();
        pthread_mutex_unlock(&lease_lock);
        if (!n) continue;
        if (recv(broker_fd, &byte, 1, MSG_TRUNC) != 1 || byte != 'N') break;
        int pair[2];
        if (g_thread_pool_unprocessed(pool) >= max_jobs || socketpair(AF_UNIX, SOCK_SEQPACKET|SOCK_CLOEXEC, 0, pair)) {
            send_fd(broker_fd, -1); continue;
        }
        int ok = send_fd(broker_fd, pair[0]);
        close(pair[0]);
        if (ok && g_thread_pool_push(pool, GINT_TO_POINTER(pair[1]), NULL)) continue;
        close(pair[1]);
    }
    return 0;
}
