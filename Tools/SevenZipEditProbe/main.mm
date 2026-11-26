// Headless, test-only FD adapter. Not shipped in the app or used as the product IPC.
#import <Foundation/Foundation.h>
#include "ArchiveSDK.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <vector>
#include <cstdio>
#include <xlocale.h>

static SevenZipInputSource snapshot(int fd) {
    struct stat s = {}; fstat(fd, &s);
    return {(uint64_t)s.st_dev, (uint64_t)s.st_ino, (uint64_t)s.st_size, s.st_mtimespec.tv_sec, s.st_ctimespec.tv_sec,
        (uint32_t)s.st_mtimespec.tv_nsec, (uint32_t)s.st_ctimespec.tv_nsec, (uint32_t)s.st_mode};
}
static int acquire(void *context, uint32_t index) {
    auto &fds = *(std::vector<int> *)context;
    return index < fds.size() && fds[index] >= 0 ? fcntl(fds[index], F_DUPFD_CLOEXEC, 3) : -1;
}
static int collect(void *context, uint32_t index, const char *path, size_t length, int kind, uint64_t size, int encrypted, const SevenZipEntryMetadata *metadata) {
    NSMutableArray *items = (__bridge NSMutableArray *)context;
    NSString *name = [[NSString alloc] initWithBytes:path length:length encoding:NSUTF8StringEncoding];
    if (!name) return 0;
    [items addObject:@{@"index":@(index), @"path":name, @"kind":@(kind), @"size":@(size), @"encrypted":@(encrypted != 0),
        @"permissions":metadata->hasPermissions ? @(metadata->permissions) : [NSNull null],
        @"modifiedSeconds":metadata->hasModifiedTime ? @(metadata->modifiedSeconds) : [NSNull null],
        @"modifiedNanos":metadata->hasModifiedTime ? @(metadata->modifiedNanos) : [NSNull null]}];
    return 1;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 4) return 2;
        unsigned char header[4]; if (fread(header, 1, 4, stdin) != 4) return 2;
        uint32_t size = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) | ((uint32_t)header[2] << 8) | header[3];
        if (!size || size > 16 * 1024 * 1024) return 2;
        NSMutableData *data = [NSMutableData dataWithLength:size]; if (fread(data.mutableBytes, 1, size, stdin) != size) return 2;
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![request isKindOfClass:[NSDictionary class]] || ![request[@"items"] isKindOfClass:[NSArray class]]) return 2;
        NSArray *entries = request[@"items"]; if (entries.count > 100000) return 2;
        std::vector<SevenZipEditItem> edits(entries.count);
        std::vector<SevenZipCreateItem> additions(entries.count);
        std::vector<int> fds(entries.count, -1);
        for (NSUInteger i = 0; i < entries.count; ++i) {
            NSDictionary *entry = entries[i];
            if (entry[@"old"] != nil) {
                edits[i].oldIndex = [entry[@"old"] unsignedIntValue];
                edits[i].renamedPath = [entry[@"path"] isKindOfClass:[NSString class]] ? [entry[@"path"] UTF8String] : nullptr;
            } else {
                auto &a = additions[i];
                a.path = [entry[@"path"] UTF8String];
                if ([entry[@"directory"] boolValue]) {
                    a.directory = 1; a.mode = S_IFDIR | 0755; a.modifiedSeconds = a.changedSeconds = 1700000000;
                    edits[i].syntheticDirectory = 1;
                } else {
                    fds[i] = [entry[@"fd"] intValue]; auto s = snapshot(fds[i]);
                    a.device = s.device; a.inode = s.inode; a.size = s.size; a.mode = s.mode;
                    a.modifiedSeconds = s.modifiedSeconds; a.modifiedNanos = s.modifiedNanos;
                    a.changedSeconds = s.changedSeconds; a.changedNanos = s.changedNanos;
                    if (entry[@"returnFD"]) fds[i] = [entry[@"returnFD"] intValue];
                }
                edits[i].oldIndex = UINT32_MAX; edits[i].addition = &a;
            }
        }
        int sourceFD = atoi(argv[2]), outputFD = atoi(argv[3]), error = 0;
        auto spec = snapshot(sourceFD);
        if (request[@"sourceSizeDelta"]) spec.size += [request[@"sourceSizeDelta"] longLongValue];
        const char *password = [request[@"password"] isKindOfClass:[NSString class]] ? [request[@"password"] UTF8String] : nullptr;
        locale_t priorLocale = uselocale(nullptr);
        void *session = [request[@"readOnlySession"] boolValue]
            ? SevenZipOpenDescriptors(argv[1], &sourceFD, &spec, 1, 0, password, &error)
            : SevenZipOpenEditDescriptor(argv[1], &sourceFD, &spec, [request[@"format"] unsignedIntValue], password, &error);
        if (session && [request[@"inspect"] boolValue]) {
            NSMutableArray *items = [NSMutableArray array];
            error = SevenZipList(session, 100000, (__bridge void *)items, collect);
            NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"error":@(error),@"items":items,@"localeRestored":@(uselocale(nullptr) == priorLocale)} options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); SevenZipClose(session); return error ? 1 : 0;
        }
        if (session && [request[@"pause"] boolValue]) { printf("{\"ready\":true}\n"); fflush(stdout); if (getchar() != 'g') { SevenZipClose(session); return 2; } }
        if (session) {
            uint64_t maximum = request[@"maximum"] ? [request[@"maximum"] unsignedLongLongValue] : 20000000000ULL;
            error = SevenZipEdit(session, outputFD, edits.data(), (uint32_t)edits.size(), [request[@"encrypt"] intValue], maximum, acquire, &fds);
            SevenZipClose(session);
        } else if (sourceFD >= 0) close(sourceFD);
        printf("{\"error\":%d,\"localeRestored\":%s}\n", error, uselocale(nullptr) == priorLocale ? "true" : "false");
        return error ? 1 : 0;
    }
}
