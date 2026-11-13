#ifndef FILES_LIBARCHIVE_SHIM_H
#define FILES_LIBARCHIVE_SHIM_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
const char *archive_entry_hardlink_utf8(struct archive_entry *);
struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_add_filter_none(struct archive *);
int archive_write_open_filename(struct archive *, const char *);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
void archive_entry_set_pathname_utf8(struct archive_entry *, const char *);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
void archive_entry_set_perm(struct archive_entry *, mode_t);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_mtime(struct archive_entry *, time_t, long);

#define FILES_ARCHIVE_OK 0
#define FILES_ARCHIVE_EOF 1
#define FILES_AE_IFREG 0100000
#define FILES_AE_IFDIR 0040000
#define FILES_AE_IFLNK 0120000
#endif
