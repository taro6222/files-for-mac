#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef int (*SevenZipItemCallback)(void *, uint32_t, const char *, size_t, int, uint64_t, int);
typedef struct { uint64_t device, inode, size; } SevenZipSourceIdentity;
void *SevenZipOpen(const char *library, const char *archive, const char *password, int *error);
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
// Output is an already-created, caller-owned seekable file. No output paths are opened.
int SevenZipCreate(const char *library, int output, const SevenZipCreateItem *items, uint32_t count,
                   const char *password, int level, int encryptHeader);

#ifdef __cplusplus
}
#endif
