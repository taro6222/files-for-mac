/* Test-only kernel authority probe. Never included in the product app. */
#include <sys/stat.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 7) return 64;
    int channel = atoi(argv[1]), output = atoi(argv[2]), inputs[2];
    char marker = 0, control[CMSG_SPACE(sizeof(inputs))];
    struct iovec io = { &marker, 1 };
    struct msghdr message = {0};
    message.msg_iov = &io; message.msg_iovlen = 1;
    message.msg_control = control; message.msg_controllen = sizeof(control);
    if (recvmsg(channel, &message, 0) != 1 || marker != 'F' || (message.msg_flags & MSG_CTRUNC)) return 65;
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    if (!header || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS || header->cmsg_len != CMSG_LEN(sizeof(inputs))) return 65;
    memcpy(inputs, CMSG_DATA(header), sizeof(inputs));
    errno = 0; int opened = open(argv[3], O_RDONLY); int open_error = errno;
    if (opened >= 0) close(opened);
    char bytes[6]; errno = 0; ssize_t count = pread(inputs[0], bytes, sizeof(bytes), 0); int read_error = errno;
    errno = 0; int mode = fchmod(inputs[0], 0600); int mode_error = errno;
    errno = 0; int timestamp = futimens(inputs[0], NULL); int timestamp_error = errno;
    errno = 0; int directory_mode = fchmod(inputs[1], 0777); int directory_error = errno;
    errno = 0; int relative = openat(inputs[1], "outside.txt", O_RDONLY); int relative_error = errno;
    if (relative >= 0) close(relative);
    errno = 0; int outside = open(argv[4], O_WRONLY | O_TRUNC); int outside_error = errno;
    if (outside >= 0) close(outside);
    errno = 0; ssize_t written = write(output, "output", 6); int write_error = errno;
    int network = socket(AF_INET, SOCK_STREAM, 0), connected = -2, connect_error = 0, bound = -2, bind_error = 0;
    if (network >= 0) {
        struct sockaddr_in address = {0}; address.sin_family = AF_INET;
        address.sin_port = htons((unsigned short)atoi(argv[6])); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        errno = 0; connected = connect(network, (struct sockaddr *)&address, sizeof(address)); connect_error = errno;
        close(network); network = socket(AF_INET, SOCK_STREAM, 0);
        address.sin_port = 0;
        if (network >= 0) { errno = 0; bound = bind(network, (struct sockaddr *)&address, sizeof(address)); bind_error = errno; close(network); }
    }
    errno = 0; ssize_t sent = send(channel, "reply", 5, 0); int send_error = errno;
    void *library = dlopen(argv[5], RTLD_NOW | RTLD_LOCAL);
    printf("{\"pathOpen\":%d,\"pathErrno\":%d,\"readBytes\":%ld,\"readErrno\":%d,\"inputMatched\":%s,"
           "\"chmod\":%d,\"chmodErrno\":%d,\"timestamp\":%d,\"timestampErrno\":%d,\"directoryChmod\":%d,\"directoryErrno\":%d,"
           "\"relativeOpen\":%d,\"relativeErrno\":%d,\"outsideWrite\":%d,\"outsideErrno\":%d,\"writeBytes\":%ld,\"writeErrno\":%d,"
           "\"connect\":%d,\"connectErrno\":%d,\"bind\":%d,\"bindErrno\":%d,\"sent\":%ld,\"sendErrno\":%d,\"libraryLoaded\":%s}\n",
           opened, open_error, (long)count, read_error, count == 6 && !memcmp(bytes, "source", 6) ? "true" : "false",
           mode, mode_error, timestamp, timestamp_error, directory_mode, directory_error, relative, relative_error, outside, outside_error,
           (long)written, write_error, connected, connect_error, bound, bind_error, (long)sent, send_error, library ? "true" : "false");
    if (library) dlclose(library);
    close(inputs[0]); close(inputs[1]);
    return 0;
}
