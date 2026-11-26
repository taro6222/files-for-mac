#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef int (*SevenZipItemCallback)(void *, uint32_t, const char *, size_t, int, uint64_t, int);
typedef struct { uint64_t device, inode, size; } SevenZipSourceIdentity;
void *SevenZipOpen(const char *library, const char *archive, const char *password, int *error);
void *SevenZipOpenVolumes(const char *library, const char *const *archives, uint32_t count, const char *password, int *error);
typedef struct {
    uint64_t device, inode, size;
    int64_t modifiedSeconds, changedSeconds;
    uint32_t modifiedNanos, changedNanos, mode;
} SevenZipInputSource;
// Adopts received read-only descriptors, setting adopted slots to -1. Caller closes remaining slots.
// The SDK never opens source paths in this mode.
void *SevenZipOpenDescriptors(const char *library, int *descriptors, const SevenZipInputSource *sources,
                             uint32_t count, int split, const char *password, int *error);
int SevenZipList(void *session, uint32_t maximumEntries, void *context, SevenZipItemCallback callback);
// Writes only one regular item's bytes to the caller-owned stream callback.
typedef int (*SevenZipWriteCallback)(void *, const void *, size_t);
int SevenZipExtract(void *session, uint32_t index, uint64_t expectedSize, uint64_t maximumBytes,
                    void *context, SevenZipWriteCallback callback, uint64_t *written);
SevenZipSourceIdentity SevenZipIdentity(void *session);
int SevenZipHeaderPasswordRequested(void *session);
void SevenZipClose(void *session);
typedef struct {
    const char *source, *path;
    uint64_t device, inode, size;
    int64_t modifiedSeconds, changedSeconds;
    uint32_t modifiedNanos, changedNanos, mode;
    int directory;
} SevenZipCreateItem;
// Returns a newly owned, read-only FD for a planned item index, or -1 on rejection.
typedef int (*SevenZipCreateInputCallback)(void *, uint32_t);
// Output is a caller-owned seekable file, or a positional-record pipe when framedOutput is set.
// The SDK never opens an output path.
int SevenZipCreate(const char *library, int output, const SevenZipCreateItem *items, uint32_t count,
                   const char *password, int level, int encryptHeader, uint32_t dictionarySize, uint32_t wordSize, uint32_t threads, int framedOutput, SevenZipCreateInputCallback inputCallback, void *inputContext);

#ifdef __cplusplus
}
#endif
