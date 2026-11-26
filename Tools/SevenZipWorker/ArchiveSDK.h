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
SevenZipSourceIdentity SevenZipIdentity(void *session);
int SevenZipHeaderPasswordRequested(void *session);
void SevenZipClose(void *session);
#ifdef __cplusplus
}
#endif
