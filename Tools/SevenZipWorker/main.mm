#import <Foundation/Foundation.h>
#include "ArchiveSDK.h"
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <math.h>
#include <fcntl.h>
#include <sys/stat.h>

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
        case 11: return @"unsupported-item"; case 12: return @"corrupt-data"; default: return @"internal";
    }
}
@interface ItemCollector : NSObject
@property NSMutableArray *items;
@property size_t pathBytes;
@property BOOL invalidMetadata;
@end
@implementation ItemCollector
@end
static int item(void *context, uint32_t index, const char *bytes, size_t length, int kind, uint64_t size, int encrypted) {
    ItemCollector *collector = (__bridge ItemCollector *)context;
    if (length > RequestLimit || collector.pathBytes + length > ResponseLimit) return 0;
    if (memchr(bytes, 0, length) || kind < 0 || kind > 4) { collector.invalidMetadata = YES; return 0; }
    NSString *path = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (!path) { collector.invalidMetadata = YES; return 0; }
    collector.pathBytes += length;
    [collector.items addObject:@{ @"index": @(index), @"path": path,
        @"kind": @[@"regularFile", @"directory", @"symbolicLink", @"hardLink", @"other"][(NSUInteger)kind],
        @"size": @(size), @"encrypted": @(encrypted != 0) }];
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        int outputDescriptor = -1;
        if (argc == 4 && strcmp(argv[2], "--output-fd") == 0) {
            char *end = nullptr; long value = strtol(argv[3], &end, 10);
            struct stat info;
            if (!*argv[3] || *end || value < 3 || value > INT_MAX || fstat((int)value, &info) != 0 ||
                !S_ISFIFO(info.st_mode) || (fcntl((int)value, F_GETFL) & O_ACCMODE) != O_WRONLY) {
                reply(failure(@"output-descriptor")); return 1;
            }
            outputDescriptor = (int)value;
        } else if (argc != 2) { reply(failure(@"arguments")); return 1; }
        void *session = nullptr;
        NSString *token = nil;
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
                NSSet *allowed = session ? [NSSet setWithArray:@[@"version", @"operation", @"session", @"maxEntries"]]
                                         : [NSSet setWithArray:@[@"version", @"operation", @"archivePath", @"password", @"maxEntries"]];
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
                if (!session) {
                    id path = request[@"archivePath"], password = request[@"password"];
                    if (!text(path, false) || (password && password != [NSNull null] && !text(password, true))) {
                        reply(failure(@"invalid-request")); result = 1; break;
                    }
                    int error = 0;
                    session = SevenZipOpen(argv[1], [path UTF8String], [password isKindOfClass:[NSString class]] ? [password UTF8String] : nullptr, &error);
                    if (!session) { reply(failure(sdkError(error))); result = 1; break; }
                    token = [[NSUUID UUID] UUIDString];
                }
                ItemCollector *collector = [ItemCollector new]; collector.items = [NSMutableArray array];
                int error = SevenZipList(session, [limit unsignedIntValue], (__bridge void *)collector, item);
                if (error) {
                    NSMutableDictionary *message = [failure(sdkError(collector.invalidMetadata ? 6 : error)) mutableCopy];
                    message[@"session"] = token;
                    if (!reply(message)) { result = 1; break; }
                    continue;
                }
                SevenZipSourceIdentity identity = SevenZipIdentity(session);
                NSDictionary *source = @{ @"device": [NSString stringWithFormat:@"%llu", (unsigned long long)identity.device],
                    @"inode": [NSString stringWithFormat:@"%llu", (unsigned long long)identity.inode], @"size": @(identity.size) };
                if (!reply(@{ @"version": @1, @"ok": @YES, @"session": token, @"source": source,
                              @"headerPasswordRequested": @(SevenZipHeaderPasswordRequested(session) != 0), @"items": collector.items })) { result = 1; break; }
            }
        }
        if (session) SevenZipClose(session);
        return result;
    }
}
