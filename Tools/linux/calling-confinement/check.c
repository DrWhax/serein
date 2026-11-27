#define _GNU_SOURCE
#include "Broker.h"
#include "CLinuxCallNetwork.h"
#include "CLinuxCallAudio.h"
#include "CLinuxSandbox.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <linux/landlock.h>
#include <sys/syscall.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

#define CHECK(test) do { if (!(test)) { fprintf(stderr,"Failed at line %d: %s (errno %d)\n",__LINE__,#test,errno); exit(1); } } while (0)
static pthread_barrier_t barrier;
static const char *marker;
static void *restricted(void *wait) {
    if (wait) pthread_barrier_wait(&barrier);
    CHECK(open(marker, O_RDONLY) < 0 && errno == EACCES);
    CHECK(open(marker, O_WRONLY) < 0 && errno == EACCES);
    CHECK(socket(AF_INET, SOCK_STREAM, 0) < 0 && errno == EPERM);
    CHECK(socket(AF_INET6, SOCK_DGRAM, 0) < 0 && errno == EPERM);
    CHECK(socket(AF_UNIX, SOCK_STREAM, 0) < 0 && errno == EPERM);
    CHECK(fork() < 0 && errno == EPERM);
    CHECK(execl("/usr/bin/false", "false", NULL) < 0 && errno == EPERM);
    return NULL;
}
static int dial(uint64_t id, const char *host, int port, enum CallNetMode mode, const char *identity,
                const uint8_t *root, size_t size, uint16_t source_port) {
    return call_net_connect(id, (const void *)host, strlen(host), port, strchr(host, ':') ? 6 : 0,
                            source_port, source_port != 0, mode, (const void *)identity, strlen(identity), root, size);
}
static void deny_local(const char *host) {
    for (int i = 0; i < 2; ++i) {
        uint64_t id = call_net_new();
        CHECK(!dial(id, host, 45671, i ? CallStream : CallDatagram, "", NULL, 0, 0));
        call_net_release(id);
    }
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--linux-call-socket-broker"))
        return serein_confine_call_broker() ? call_net_serve_broker() : 78;
    if (argc != 6) { fprintf(stderr, "Usage: check readable-marker own-IP remote-peer peer-port root.der\n"); return 2; }
    marker = argv[1];
    int own_file = open(marker, O_RDONLY);
    CHECK(own_file >= 0);
    close(own_file);
    g_autofree char *root = NULL; size_t size = 0;
    CHECK(g_file_get_contents(argv[5], &root, &size, NULL));
    CHECK(call_net_start_broker());
    pthread_t before, after;
    long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    CHECK(abi >= 6 && !pthread_barrier_init(&barrier, NULL, 2));
    if (abi >= 8) CHECK(!pthread_create(&before, NULL, restricted, &before));
    CHECK(serein_confine_call_worker() && serein_is_call_worker_confined());
    if (abi < 8) CHECK(!pthread_create(&before, NULL, restricted, &before));
    pthread_barrier_wait(&barrier);
    CHECK(!pthread_join(before, NULL) && !pthread_create(&after, NULL, restricted, NULL) && !pthread_join(after, NULL));
    restricted(NULL);
    int certs = open("/etc/ssl/certs/ca-certificates.crt", O_RDONLY);
    CHECK(certs >= 0);
    close(certs);
    deny_local("127.0.0.1"); deny_local("127.0.0.2"); deny_local("::1");
    deny_local("localhost"); deny_local("0.0.0.0"); deny_local("::ffff:127.0.0.1"); deny_local(argv[2]);
    puts("User files, process creation, direct sockets and local calling destinations denied.");
    uint8_t interfaces[32768];
    CHECK(call_net_interfaces(interfaces, sizeof(interfaces)) > 0);

    int lease = -1;
    int fd = call_broker_listen(1, NULL, &lease);
    CHECK(fd >= 0);
    struct sockaddr_in local = {.sin_family = AF_INET, .sin_port=htons(45671), .sin_addr={htonl(INADDR_LOOPBACK)}};
    CHECK(connect(fd, (void *)&local, sizeof(local)) < 0 && errno == EPERM);
    CHECK(sendto(fd, "x", 1, 0, (void *)&local, sizeof(local)) < 0 && errno == EPERM);
    struct iovec iov = {"x", 1};
    struct msghdr msg = {.msg_name=&local, .msg_namelen=sizeof(local), .msg_iov=&iov, .msg_iovlen=1};
    CHECK(sendmsg(fd, &msg, 0) < 0 && errno == EPERM);
    close(fd);
    close(lease);

    struct SereinPCMOpen mic = serein_call_pcm_open(NULL, 0, 1), speaker = serein_call_pcm_open(NULL, 0, 0);
    CHECK(mic.handle && speaker.handle);
    int16_t samples[960] = {0};
    int captured = 0;
    for (int i = 0; !captured && i < 100; ++i) {
        captured = serein_call_pcm_read(mic.handle, samples, 960).status == 1;
        if (!captured) usleep(5000);
    }
    CHECK(captured);
    CHECK(serein_call_pcm_play(speaker.handle, samples, 960, serein_audio_host_frame() + 960, 0, 1).status == 1);
    serein_call_pcm_close(mic.handle); serein_call_pcm_close(speaker.handle);
    puts("Confined ALSA capture and playback completed.");

    const char *host = argv[3]; int port = atoi(argv[4]);
    uint64_t listen = call_net_new(), connection = call_net_new();
    CHECK(call_net_listen(listen, 1));
    uint8_t address[16];
    struct CallNetAddress bound = call_net_local(listen, address, sizeof(address));
    CHECK(bound.port && dial(connection, host, port, CallDatagram, "", NULL, 0, bound.port));
    const uint8_t hello[] = {'i', 'c', 'e'};
    CHECK(call_net_write(connection, hello, sizeof(hello)));
    uint8_t received[256];
    CHECK(call_net_read(connection, received, sizeof(received)) == 3 && !memcmp(received, hello, 3));
    struct CallNetPeer inbound = call_net_accept(listen, received, sizeof(received), address, sizeof(address));
    CHECK(inbound.id && inbound.count == 5 && !memcmp(received, "offer", 5));
    CHECK(call_net_write(inbound.id, (const uint8_t *)"answer", 6));
    CHECK(call_net_read(inbound.id, received, sizeof(received)) == 4 && !memcmp(received, "done", 4));
    call_net_release(inbound.id); call_net_release(connection); call_net_release(listen);
    connection = call_net_new();
    CHECK(!dial(connection, host, port, CallDatagram, "", NULL, 0, bound.port));
    call_net_release(connection);
    puts("Inbound and outbound media share the leased UDP port; the released port is unavailable.");

    for (int attempt = 0; attempt < 3; ++attempt) {
        uint64_t tls = call_net_new();
        int ok = dial(tls, host, port, CallTLS, attempt == 1 ? "wrong.invalid" : "relay.invalid",
                      attempt ? (const uint8_t *)root : NULL, attempt ? size : 0, 0);
        CHECK(ok == (attempt == 2));
        if (ok) {
            CHECK(call_net_write(tls, hello, sizeof(hello)));
            CHECK(call_net_read(tls, received, sizeof(received)) == 3 && !memcmp(received, hello, 3));
        }
        call_net_release(tls);
    }
    puts("TLS accepted the trusted relay and rejected a wrong name and an untrusted root.");
    return 0;
}
