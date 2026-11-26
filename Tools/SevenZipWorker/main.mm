#import <Foundation/Foundation.h>
#include "ArchiveSDK.h"
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <math.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <mutex>
#include <vector>

static const size_t RequestLimit = 1024 * 1024, ResponseLimit = 8 * 1024 * 1024;
static ssize_t readExact(void *bytes, size_t count) {
    size_t total = 0;
    while (total < count) {
        ssize_t result = read(STDIN_FILENO, (char *)bytes + total, count - total);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) return -1;
        if (result == 0) break;
        total += result;
    }
    return (ssize_t)total;
}
static bool writeExact(const void *bytes, size_t count) {
    size_t total = 0;
    while (total < count) {
        ssize_t result = write(STDOUT_FILENO, (const char *)bytes + total, count - total);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) return false;
        total += result;
    }
    return true;
}
static NSDictionary *failure(NSString *code) { return @{ @"version": @1, @"ok": @NO, @"error": @{ @"code": code } }; }
static bool reply(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (!data || data.length > ResponseLimit) data = [NSJSONSerialization dataWithJSONObject:failure(@"response-limit") options:0 error:nil];
    uint32_t length = htonl((uint32_t)data.length);
    return writeExact(&length, sizeof(length)) && writeExact(data.bytes, data.length);
}
static bool integer(id value, int64_t minimum, int64_t maximum) {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
    double number = [value doubleValue];
    return isfinite(number) && number == floor(number) && number >= minimum && number <= maximum;
}
static bool text(id value, bool allowEmpty) {
    if (![value isKindOfClass:[NSString class]] || (!allowEmpty && [value length] == 0)) return false;
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    return data && !memchr(data.bytes, 0, data.length);
}
static NSString *sdkError(int value) {
    switch (value) {
        case 1: return @"sdk-load"; case 2: return @"source-open"; case 3: return @"password-required";
        case 4: return @"password-or-corrupt"; case 5: return @"not-archive"; case 6: return @"invalid-metadata";
        case 7: return @"limit"; case 9: return @"source-changed"; case 10: return @"output-write";
        case 11: return @"unsupported-item"; case 12: return @"corrupt-data"; case 13: return @"missing-volume"; default: return @"internal";
    }
}
@interface ItemCollector : NSObject
@property NSMutableArray *items;
@property size_t pathBytes;
@property BOOL invalidMetadata;
@property BOOL paged;
@property size_t encodedBytes;
@end
@implementation ItemCollector
@end
static int item(void *context, uint32_t index, const char *bytes, size_t length, int kind, uint64_t size, int encrypted, const SevenZipEntryMetadata *metadata) {
    ItemCollector *collector = (__bridge ItemCollector *)context;
    if (length > RequestLimit || (!collector.paged && collector.pathBytes + length > ResponseLimit)) return 0;
    if (memchr(bytes, 0, length) || kind < 0 || kind > 4) { collector.invalidMetadata = YES; return 0; }
    NSString *path = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (!path) { collector.invalidMetadata = YES; return 0; }
    NSDictionary *record = @{ @"index": @(index), @"path": path,
        @"kind": @[@"regularFile", @"directory", @"symbolicLink", @"hardLink", @"other"][(NSUInteger)kind],
        @"size": @(size), @"encrypted": @(encrypted != 0),
        @"metadata": @{ @"permissions": metadata->hasPermissions ? @(metadata->permissions) : [NSNull null],
            @"modifiedSeconds": metadata->hasModifiedTime ? @(metadata->modifiedSeconds) : [NSNull null],
            @"modifiedNanos": metadata->hasModifiedTime ? @(metadata->modifiedNanos) : [NSNull null] } };
    if (collector.paged) {
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
        if (!encoded || encoded.length > ResponseLimit - 4096) return 0;
        if (collector.items.count && collector.encodedBytes + encoded.length + 1 > 4 * 1024 * 1024) return 2;
        collector.encodedBytes += encoded.length + 1;
    }
    collector.pathBytes += length;
    [collector.items addObject:record];
    return 1;
}
static int outputBytes(void *context, const void *bytes, size_t length) {
    int descriptor = *(int *)context;
    size_t total = 0;
    while (total < length) {
        ssize_t count = write(descriptor, (const char *)bytes + total, length - total);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return 0;
        total += count;
    }
    return 1;
}

static bool unsignedText(id value, uint64_t *number) {
    if (!text(value, false)) return false;
    const char *bytes = [value UTF8String];
    for (const char *p = bytes; *p; ++p) if (*p < '0' || *p > '9') return false;
    char *end = nullptr; errno = 0;
    unsigned long long result = strtoull(bytes, &end, 10);
    if (errno || *end) return false;
    *number = result; return true;
}
struct CreateBroker {
    int socket; uint32_t count; std::mutex lock; bool invalid = false;
    CreateBroker(int value, uint32_t size): socket(value), count(size) {}
};
static int acquireCreateInput(void *context, uint32_t index);
static int createArchive(const char *library, int output, NSDictionary *request, bool framedOutput, int inputDescriptor) {
    NSSet *allowed = [NSSet setWithArray:@[@"version", @"operation", @"items", @"password", @"level", @"encryptHeader", @"dictionarySize", @"wordSize", @"threads"]];
    id password = request[@"password"], level = request[@"level"], header = request[@"encryptHeader"], items = request[@"items"];
    if (![[NSSet setWithArray:request.allKeys] isSubsetOfSet:allowed] ||
        ![items isKindOfClass:[NSArray class]] || [items count] == 0 || [items count] > 100000 ||
        !integer(level, 0, 9) || ![@[@0, @1, @3, @5, @7, @9] containsObject:level] ||
        ![header isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)header) != CFBooleanGetTypeID() ||
        (password && password != [NSNull null] && !text(password, false)) ||
        ([header boolValue] && ![password isKindOfClass:[NSString class]])) return 6;
    id dictionary = request[@"dictionarySize"] ?: @0, word = request[@"wordSize"] ?: @0, threads = request[@"threads"] ?: @2;
    if (!integer(dictionary, 0, 1073741824) || !integer(word, 0, 273) || !integer(threads, 1, 512)) return 6;
    uint32_t dictionarySize = [dictionary unsignedIntValue], wordSize = [word unsignedIntValue];
    if (dictionarySize && dictionarySize != 65536 && dictionarySize != 262144 &&
        (dictionarySize < 1048576 || (dictionarySize & (dictionarySize - 1)) != 0)) return 6;
    if (![@[@0, @8, @16, @32, @64, @128, @256, @273] containsObject:word]) return 6;
    if (!dictionarySize) {
        switch ([level intValue]) {
            case 9: dictionarySize = 64U << 20; break;
            case 7: dictionarySize = 32U << 20; break;
            case 5: dictionarySize = 16U << 20; break;
            case 3: dictionarySize = 1U << 20; break;
            default: dictionarySize = 64U << 10; break;
        }
    }
    if (!wordSize) wordSize = [level intValue] >= 7 ? 64 : 32;
    std::vector<SevenZipCreateItem> entries;
    uint64_t total = 0;
    NSMutableSet *paths = [NSMutableSet set];
    NSMutableSet *itemKeys = [NSMutableSet setWithArray:@[@"path", @"device", @"inode", @"size", @"modifiedSeconds", @"modifiedNanos", @"changedSeconds", @"changedNanos", @"mode", @"directory"]];
    if (inputDescriptor < 0) [itemKeys addObject:@"source"];
    for (id item in items) {
        if (![item isKindOfClass:[NSDictionary class]] || ![[NSSet setWithArray:[item allKeys]] isEqualToSet:itemKeys] ||
            (inputDescriptor < 0 && (!text(item[@"source"], false) || ![item[@"source"] hasPrefix:@"/"])) || !text(item[@"path"], false) ||
            [item[@"path"] hasPrefix:@"/"] || [paths containsObject:item[@"path"]] ||
            !integer(item[@"size"], 0, 8000000000LL) || !integer(item[@"mode"], 0, UINT32_MAX) ||
            !integer(item[@"modifiedSeconds"], -11644473600LL, 100000000000LL) ||
            !integer(item[@"changedSeconds"], -11644473600LL, 100000000000LL) ||
            !integer(item[@"modifiedNanos"], 0, 999999999) || !integer(item[@"changedNanos"], 0, 999999999) ||
            !integer(item[@"directory"], 0, 1)) return 6;
        for (NSString *part in [item[@"path"] componentsSeparatedByString:@"/"]) {
            if (!part.length || [part isEqual:@"."] || [part isEqual:@".."] || [part containsString:@"\\"]) return 6;
        }
        SevenZipCreateItem entry = {};
        if (!unsignedText(item[@"device"], &entry.device) || !unsignedText(item[@"inode"], &entry.inode)) return 6;
        entry.source = inputDescriptor < 0 ? [item[@"source"] UTF8String] : nullptr; entry.path = [item[@"path"] UTF8String];
        entry.size = [item[@"size"] unsignedLongLongValue]; entry.mode = [item[@"mode"] unsignedIntValue];
        entry.modifiedSeconds = [item[@"modifiedSeconds"] longLongValue]; entry.modifiedNanos = [item[@"modifiedNanos"] unsignedIntValue];
        entry.changedSeconds = [item[@"changedSeconds"] longLongValue]; entry.changedNanos = [item[@"changedNanos"] unsignedIntValue];
        entry.directory = [item[@"directory"] intValue];
        if (entry.directory && entry.size) return 6;
        total += entry.size; if (total > 8000000000ULL) return 7;
        entries.push_back(entry); [paths addObject:item[@"path"]];
    }
    CreateBroker broker(inputDescriptor, (uint32_t)entries.size());
    int error = SevenZipCreate(library, output, entries.data(), (uint32_t)entries.size(),
        [password isKindOfClass:[NSString class]] ? [password UTF8String] : nullptr, [level intValue], [header boolValue], dictionarySize, wordSize, [threads unsignedIntValue], framedOutput ? 1 : 0,
        inputDescriptor < 0 ? nullptr : acquireCreateInput, &broker);
    return broker.invalid ? 6 : error;
}

struct ReceivedDescriptors {
    std::vector<int> values;
    ~ReceivedDescriptors() { for (int fd: values) if (fd >= 0) close(fd); }
};
static bool signedInteger(id value) {
    return [value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] == floor([value doubleValue]) &&
        [value compare:@(INT64_MIN)] != NSOrderedAscending && [value compare:@(INT64_MAX)] != NSOrderedDescending;
}
static int receiveDescriptor(int socket, bool allowDirectory, int *result) {
    ReceivedDescriptors received;
    unsigned char marker = 0;
    struct iovec vector = { &marker, 1 };
    union { struct cmsghdr alignment; unsigned char bytes[CMSG_SPACE(sizeof(int))]; } control = {};
    struct msghdr message = {}; message.msg_iov = &vector; message.msg_iovlen = 1;
    message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
    ssize_t count;
    do { count = recvmsg(socket, &message, 0); } while (count < 0 && errno == EINTR);
    bool shape = count == 1 && marker == 0x46 && !(message.msg_flags & (MSG_CTRUNC | MSG_TRUNC));
    if (message.msg_controllen > sizeof(control.bytes)) { message.msg_controllen = sizeof(control.bytes); shape = false; }
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
        size_t remaining = control.bytes + message.msg_controllen - (unsigned char *)header;
        if (header->cmsg_len < CMSG_LEN(0) || header->cmsg_len > remaining) { shape = false; break; }
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) { shape = false; continue; }
        size_t bytes = header->cmsg_len - CMSG_LEN(0);
        if (bytes % sizeof(int)) shape = false;
        for (size_t j = 0; j + sizeof(int) <= bytes; j += sizeof(int)) {
            int fd; memcpy(&fd, CMSG_DATA(header) + j, sizeof(fd)); received.values.push_back(fd);
        }
    }
    if (!shape || received.values.size() != 1) return 6;
    int fd = received.values.back(); struct stat info;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 || (fcntl(fd, F_GETFL) & O_ACCMODE) != O_RDONLY ||
        fstat(fd, &info) != 0 || !(S_ISREG(info.st_mode) || (allowDirectory && S_ISDIR(info.st_mode)))) return 2;
    *result = fd; received.values.clear(); return 0;
}
static int acquireCreateInput(void *context, uint32_t index) {
    auto &broker = *(CreateBroker *)context;
    std::lock_guard<std::mutex> guard(broker.lock);
    if (index >= broker.count) { broker.invalid = true; return -1; }
    unsigned char request[5] = { 0x43, (unsigned char)(index >> 24), (unsigned char)(index >> 16), (unsigned char)(index >> 8), (unsigned char)index };
    size_t sent = 0;
    while (sent < sizeof(request)) {
        ssize_t count = send(broker.socket, request + sent, sizeof(request) - sent, MSG_NOSIGNAL);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { broker.invalid = true; return -1; }
        sent += (size_t)count;
    }
    int fd = -1;
    if (receiveDescriptor(broker.socket, true, &fd) != 0) { broker.invalid = true; return -1; }
    return fd;
}
static int receiveSources(int socket, id specs, id split, ReceivedDescriptors &received, std::vector<SevenZipInputSource> &sources) {
    if (![specs isKindOfClass:[NSArray class]] || [specs count] == 0 || [specs count] > 1024 ||
        ![split isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)split) != CFBooleanGetTypeID() ||
        (![split boolValue] && [specs count] != 1)) return 6;
    NSSet *keys = [NSSet setWithArray:@[@"device", @"inode", @"size", @"mode", @"modifiedSeconds", @"modifiedNanos", @"changedSeconds", @"changedNanos"]];
    for (id item in specs) {
        if (![item isKindOfClass:[NSDictionary class]] || ![[NSSet setWithArray:[item allKeys]] isEqualToSet:keys] ||
            !integer(item[@"size"], 0, INT64_MAX) || !integer(item[@"mode"], 0, UINT32_MAX) ||
            !signedInteger(item[@"modifiedSeconds"]) || !signedInteger(item[@"changedSeconds"]) ||
            !integer(item[@"modifiedNanos"], 0, 999999999) || !integer(item[@"changedNanos"], 0, 999999999)) return 6;
        SevenZipInputSource source = {};
        if (!unsignedText(item[@"device"], &source.device) || !unsignedText(item[@"inode"], &source.inode)) return 6;
        source.size = [item[@"size"] unsignedLongLongValue]; source.mode = [item[@"mode"] unsignedIntValue];
        source.modifiedSeconds = [item[@"modifiedSeconds"] longLongValue]; source.modifiedNanos = [item[@"modifiedNanos"] unsignedIntValue];
        source.changedSeconds = [item[@"changedSeconds"] longLongValue]; source.changedNanos = [item[@"changedNanos"] unsignedIntValue];
        sources.push_back(source);
    }
    struct rlimit limit; rlim_t needed = (rlim_t)sources.size() + 64;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0 || limit.rlim_max < needed) return 7;
    if (limit.rlim_cur < needed) { limit.rlim_cur = needed; if (setrlimit(RLIMIT_NOFILE, &limit) != 0) return 7; }
    for (size_t i = 0; i < sources.size(); ++i) {
        int fd = -1; int error = receiveDescriptor(socket, false, &fd);
        if (error) return error;
        received.values.push_back(fd);
    }
    unsigned char extra = 0; ssize_t count;
    do { count = read(socket, &extra, 1); } while (count < 0 && errno == EINTR);
    return count == 0 ? 0 : 6;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        int outputDescriptor = -1, inputDescriptor = -1;
        bool creation = false, framedCreation = false;
        if (argc != 2 && argc != 4 && argc != 6) { reply(failure(@"arguments")); return 1; }
        for (int i = 2; i < argc; i += 2) {
            char *end = nullptr; long value = strtol(argv[i + 1], &end, 10);
            if (!*argv[i + 1] || !end || *end || value < 3 || value > INT_MAX) { reply(failure(@"output-descriptor")); return 1; }
            if (strcmp(argv[i], "--input-fd") == 0) {
                int type = 0; socklen_t length = sizeof(type); struct sockaddr_storage address = {}; socklen_t addressLength = sizeof(address);
                if (inputDescriptor >= 0 || getsockopt((int)value, SOL_SOCKET, SO_TYPE, &type, &length) != 0 || type != SOCK_STREAM ||
                    getsockname((int)value, (struct sockaddr *)&address, &addressLength) != 0 || address.ss_family != AF_UNIX) { reply(failure(@"input-descriptor")); return 1; }
                inputDescriptor = (int)value; continue;
            }
            if (outputDescriptor >= 0) { reply(failure(@"arguments")); return 1; }
            creation = strcmp(argv[i], "--create-output-fd") == 0 || strcmp(argv[i], "--create-stream-fd") == 0;
            framedCreation = strcmp(argv[i], "--create-stream-fd") == 0;
            if (!creation && strcmp(argv[i], "--output-fd") != 0) { reply(failure(@"arguments")); return 1; }
            struct stat info;
            if (fstat((int)value, &info) != 0 ||
                (creation && !framedCreation ? (!S_ISREG(info.st_mode) || info.st_size != 0 || info.st_nlink != 1 || (fcntl((int)value, F_GETFL) & O_APPEND) || lseek((int)value, 0, SEEK_CUR) != 0)
                          : !S_ISFIFO(info.st_mode)) || (fcntl((int)value, F_GETFL) & O_ACCMODE) != O_WRONLY) {
                reply(failure(@"output-descriptor")); return 1;
            }
            outputDescriptor = (int)value;
        }
        if (inputDescriptor >= 0 && inputDescriptor == outputDescriptor) { reply(failure(@"input-descriptor")); return 1; }
        const bool descriptorInput = inputDescriptor >= 0;
        void *session = nullptr;
        NSString *token = nil;
        NSMutableDictionary *creationRequest = nil;
        NSMutableArray *creationItems = nil;
        NSString *upload = nil;
        NSUInteger expectedItems = 0;
        uint64_t creationBytes = 0;
        int result = 0;
        while (true) {
            @autoreleasepool {
                uint32_t header = 0;
                ssize_t received = readExact(&header, sizeof(header));
                if (received == 0 && session) break;
                if (received != sizeof(header)) { reply(failure(@"truncated-frame")); result = 1; break; }
                size_t length = ntohl(header);
                if (length == 0 || length > RequestLimit) { reply(failure(@"frame-limit")); result = 1; break; }
                NSMutableData *data = [NSMutableData dataWithLength:length];
                if (readExact(data.mutableBytes, length) != (ssize_t)length) { reply(failure(@"truncated-frame")); result = 1; break; }
                id request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (![request isKindOfClass:[NSDictionary class]] || !integer(request[@"version"], 1, 1) || !text(request[@"operation"], false)) {
                    reply(failure(@"invalid-request")); result = 1; break;
                }
                if (creation) {
                    NSString *operation = request[@"operation"];
                    if ([operation isEqual:@"create-begin"]) {
                        NSSet *allowed = [NSSet setWithArray:@[@"version", @"operation", @"itemCount", @"password", @"level", @"encryptHeader", @"dictionarySize", @"wordSize", @"threads"]];
                        if (creationRequest || inputDescriptor < 0 || ![[NSSet setWithArray:[request allKeys]] isSubsetOfSet:allowed] ||
                            !integer(request[@"itemCount"], 1, 100000)) { reply(failure(@"invalid-request")); result = 1; break; }
                        expectedItems = [request[@"itemCount"] unsignedIntegerValue];
                        creationRequest = [request mutableCopy];
                        [creationRequest removeObjectForKey:@"itemCount"];
                        creationRequest[@"operation"] = @"create";
                        creationItems = [NSMutableArray array];
                        creationBytes = length;
                        upload = [[NSUUID UUID] UUIDString];
                        if (!reply(@{ @"version": @1, @"ok": @YES, @"upload": upload, @"accepted": @0 })) { result = 1; break; }
                        continue;
                    }
                    if (creationRequest) {
                        if (!text(request[@"upload"], false) || ![upload isEqual:request[@"upload"]]) { reply(failure(@"invalid-request")); result = 1; break; }
                        if ([operation isEqual:@"create-items"]) {
                            NSSet *keys = [NSSet setWithArray:@[@"version", @"operation", @"upload", @"offset", @"items"]];
                            id items = request[@"items"];
                            if (![[NSSet setWithArray:[request allKeys]] isEqualToSet:keys] ||
                                !integer(request[@"offset"], 0, 100000) || [request[@"offset"] unsignedIntegerValue] != creationItems.count ||
                                ![items isKindOfClass:[NSArray class]] || [items count] == 0 || [items count] > 256 ||
                                creationItems.count + [items count] > expectedItems) { reply(failure(@"invalid-request")); result = 1; break; }
                            creationBytes += length;
                            if (creationBytes > 256ULL * 1024 * 1024) { reply(failure(@"limit")); result = 1; break; }
                            BOOL valid = YES;
                            for (id item in items) if (![item isKindOfClass:[NSDictionary class]]) { valid = NO; break; }
                            if (!valid) { reply(failure(@"invalid-request")); result = 1; break; }
                            [creationItems addObjectsFromArray:items];
                            if (!reply(@{ @"version": @1, @"ok": @YES, @"upload": upload, @"accepted": @(creationItems.count) })) { result = 1; break; }
                            continue;
                        }
                        NSSet *keys = [NSSet setWithArray:@[@"version", @"operation", @"upload"]];
                        if (![operation isEqual:@"create-commit"] || ![[NSSet setWithArray:[request allKeys]] isEqualToSet:keys] ||
                            creationItems.count != expectedItems) { reply(failure(@"invalid-request")); result = 1; break; }
                        creationRequest[@"items"] = creationItems;
                        request = creationRequest;
                    } else if (![operation isEqual:@"create"]) { reply(failure(@"unsupported-operation")); result = 1; break; }
                    int error = createArchive(argv[1], outputDescriptor, request, framedCreation, inputDescriptor);
                    if (inputDescriptor >= 0) { close(inputDescriptor); inputDescriptor = -1; }
                    reply(error ? failure(sdkError(error)) : @{ @"version": @1, @"ok": @YES, @"closed": @YES });
                    result = error ? 1 : 0; break;
                }
                NSSet *allowed = session ? [NSSet setWithArray:@[@"version", @"operation", @"session", @"maxEntries", @"offset", @"pageSize"]]
                                         : (descriptorInput ? [NSSet setWithArray:@[@"version", @"operation", @"sourceFDs", @"splitVolumes", @"password", @"maxEntries", @"offset", @"pageSize"]]
                                                            : [NSSet setWithArray:@[@"version", @"operation", @"archivePath", @"archivePaths", @"password", @"maxEntries", @"offset", @"pageSize"]]);
                if (session && [request[@"operation"] isEqual:@"extract"]) {
                    allowed = [NSSet setWithArray:@[@"version", @"operation", @"session", @"index", @"expectedSize", @"maximumBytes"]];
                }
                bool valid = [[NSSet setWithArray:[request allKeys]] isSubsetOfSet:allowed];
                if (session && ![request[@"session"] isEqual:token]) valid = false;
                id limit = request[@"maxEntries"] ?: @100000;
                if (!valid || !integer(limit, 1, 100000)) { reply(failure(@"invalid-request")); result = 1; break; }
                if (session && [request[@"operation"] isEqual:@"extract"]) {
                    if (!integer(request[@"index"], 0, UINT32_MAX) || !integer(request[@"expectedSize"], 0, 8000000000LL) ||
                        !integer(request[@"maximumBytes"], 0, 8000000000LL)) {
                        reply(failure(@"invalid-request")); result = 1; break;
                    }
                    if (outputDescriptor < 0) { reply(failure(@"output-descriptor")); result = 1; break; }
                    uint64_t written = 0;
                    int error = SevenZipExtract(session, [request[@"index"] unsignedIntValue], [request[@"expectedSize"] unsignedLongLongValue],
                        [request[@"maximumBytes"] unsignedLongLongValue], &outputDescriptor, outputBytes, &written);
                    NSMutableDictionary *message = error ? [failure(sdkError(error)) mutableCopy] : [@{ @"version": @1, @"ok": @YES } mutableCopy];
                    message[@"session"] = token; message[@"written"] = @(written);
                    if (!reply(message)) { result = 1; break; }
                    continue;
                }
                if ([request[@"operation"] isEqual:@"close"] && session) {
                    SevenZipClose(session); session = nullptr;
                    reply(@{ @"version": @1, @"ok": @YES, @"closed": @YES }); break;
                }
                if (![request[@"operation"] isEqual:@"list"]) { reply(failure(@"unsupported-operation")); result = 1; break; }
                bool paged = request[@"offset"] || request[@"pageSize"];
                if (paged && (!integer(request[@"offset"], 0, 100000) || !integer(request[@"pageSize"], 1, 256))) {
                    reply(failure(@"invalid-request")); result = 1; break;
                }
                if (!session) {
                    id password = request[@"password"];
                    if (password && password != [NSNull null] && !text(password, true)) { reply(failure(@"invalid-request")); result = 1; break; }
                    int error = 0;
                    const char *secret = [password isKindOfClass:[NSString class]] ? [password UTF8String] : nullptr;
                    if (descriptorInput) {
                        ReceivedDescriptors received; std::vector<SevenZipInputSource> sources;
                        error = receiveSources(inputDescriptor, request[@"sourceFDs"], request[@"splitVolumes"], received, sources);
                        close(inputDescriptor); inputDescriptor = -1;
                        if (!error) session = SevenZipOpenDescriptors(argv[1], received.values.data(), sources.data(), (uint32_t)sources.size(), [request[@"splitVolumes"] boolValue], secret, &error);
                    } else {
                        id path = request[@"archivePath"], paths = request[@"archivePaths"];
                        bool multi = paths != nil;
                        bool validPaths = multi ? (!path && [paths isKindOfClass:[NSArray class]] && [paths count] > 0 && [paths count] <= 1024) : text(path, false);
                        std::vector<const char *> sourcePaths;
                        if (validPaths && multi) {
                            for (id value in paths) {
                                if (!text(value, false)) { validPaths = false; break; }
                                sourcePaths.push_back([value UTF8String]);
                            }
                        }
                        if (!validPaths || (password && password != [NSNull null] && !text(password, true))) {
                            reply(failure(@"invalid-request")); result = 1; break;
                        }
                        session = multi ? SevenZipOpenVolumes(argv[1], sourcePaths.data(), (uint32_t)sourcePaths.size(), secret, &error)
                                        : SevenZipOpen(argv[1], [path UTF8String], secret, &error);
                    }
                    if (!session) { reply(failure(sdkError(error))); result = 1; break; }
                    token = [[NSUUID UUID] UUIDString];
                }
                ItemCollector *collector = [ItemCollector new]; collector.items = [NSMutableArray array]; collector.paged = paged;
                uint32_t total = 0;
                int error = paged ? SevenZipListPage(session, [limit unsignedIntValue], [request[@"offset"] unsignedIntValue],
                    [request[@"pageSize"] unsignedIntValue], (__bridge void *)collector, item, &total)
                    : SevenZipList(session, [limit unsignedIntValue], (__bridge void *)collector, item);
                if (error) {
                    NSMutableDictionary *message = [failure(sdkError(collector.invalidMetadata ? 6 : error)) mutableCopy];
                    message[@"session"] = token;
                    if (!reply(message)) { result = 1; break; }
                    continue;
                }
                SevenZipSourceIdentity identity = SevenZipIdentity(session);
                NSDictionary *source = @{ @"device": [NSString stringWithFormat:@"%llu", (unsigned long long)identity.device],
                    @"inode": [NSString stringWithFormat:@"%llu", (unsigned long long)identity.inode], @"size": @(identity.size) };
                NSMutableDictionary *message = [@{ @"version": @1, @"ok": @YES, @"session": token, @"source": source,
                    @"headerPasswordRequested": @(SevenZipHeaderPasswordRequested(session) != 0), @"items": collector.items } mutableCopy];
                if (paged) { message[@"offset"] = request[@"offset"]; message[@"total"] = @(total); }
                if (!reply(message)) { result = 1; break; }
            }
        }
        if (session) SevenZipClose(session);
        return result;
    }
}
