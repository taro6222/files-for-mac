#include "ArchiveSDK.h"
#include "CPP/Common/MyWindows.h"
#include "CPP/Common/MyInitGuid.h"
#include "CPP/Common/MyCom.h"
#include "CPP/Common/MyString.h"
#include "CPP/Common/UTFConvert.h"
#include "CPP/Windows/PropVariant.h"
#include "CPP/7zip/Archive/IArchive.h"
#include "CPP/7zip/IPassword.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <limits.h>
#include <memory>
#include <errno.h>
#include <string>
#include <string.h>
#include <vector>
#include <algorithm>
#include <mutex>
#include <set>
#include <CoreFoundation/CoreFoundation.h>
#include <xlocale.h>
#include <sys/resource.h>
#include <CommonCrypto/CommonDigest.h>
#include <array>

Z7_DEFINE_GUID(CLSID_SevenZip, 0x23170f69, 0x40c1, 0x278a, 0x10, 0, 0, 1, 0x10, 7, 0, 0);
Z7_DEFINE_GUID(CLSID_Zip, 0x23170f69, 0x40c1, 0x278a, 0x10, 0, 0, 1, 0x10, 1, 0, 0);

// ZIP's SDK password decoder uses the C multibyte conversion. Scope UTF-8 to
// this thread; changing the process locale would affect unrelated host work.
class EditLocale {
    locale_t utf8 = nullptr, previous = nullptr;
    bool enabled;
public:
    explicit EditLocale(bool value): enabled(value) {
        if (enabled) { utf8 = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nullptr); if (utf8) previous = uselocale(utf8); }
    }
    bool valid() const { return !enabled || (utf8 && previous); }
    ~EditLocale() { if (previous) uselocale(previous); if (utf8) freelocale(utf8); }
};

class SourceStream final: public IInStream, public CMyUnknownImp {
    Z7_COM_UNKNOWN_IMP_2(IInStream, ISequentialInStream)
    struct Part { int fd; struct stat info; uint64_t start; std::string path; bool checkPath; };
    std::vector<Part> parts;
    uint64_t position = 0;
    size_t cursor = 0;
    static bool same(const struct stat &a, const struct stat &b) {
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
    }
public:
    struct stat initial = {};
    uint64_t total = 0;
    bool containsIdentity(const struct stat &info) const {
        for (const auto &part: parts) if (part.info.st_dev == info.st_dev && part.info.st_ino == info.st_ino) return true;
        return false;
    }
    ~SourceStream() { for (const auto &part: parts) close(part.fd); }
    int append(const char *path, bool split) {
        int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | (split ? O_NOFOLLOW : 0));
        if (fd < 0) return errno == EMFILE ? 7 : 2;
        struct stat info;
        if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0) { close(fd); return 2; }
        uint64_t maximum = split ? 8000000000ULL : INT64_MAX;
        if ((uint64_t)info.st_size > maximum - total) { close(fd); return 7; }
        if (split && (info.st_size == 0 || (!parts.empty() && info.st_size > initial.st_size))) { close(fd); return 6; }
        if (split && parts.size() > 1 && parts.back().info.st_size != initial.st_size) { close(fd); return 6; }
        try { parts.push_back({fd, info, total, path, split}); } catch (...) { close(fd); throw; }
        if (parts.size() == 1) initial = info;
        total += (uint64_t)info.st_size;
        return 0;
    }
    int appendDescriptor(int &source, const SevenZipInputSource &expected, bool split) {
        int fd = source; source = -1;
        if (fd < 0) return 2;
        struct stat info;
        if ((fcntl(fd, F_GETFL) & O_ACCMODE) != O_RDONLY || fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0) { close(fd); return 2; }
        if ((uint64_t)info.st_dev != expected.device || (uint64_t)info.st_ino != expected.inode || (uint64_t)info.st_size != expected.size ||
            (uint32_t)info.st_mode != expected.mode || info.st_mtimespec.tv_sec != expected.modifiedSeconds ||
            info.st_mtimespec.tv_nsec != expected.modifiedNanos || info.st_ctimespec.tv_sec != expected.changedSeconds || info.st_ctimespec.tv_nsec != expected.changedNanos) { close(fd); return 9; }
        uint64_t maximum = split ? 8000000000ULL : INT64_MAX;
        if ((uint64_t)info.st_size > maximum - total) { close(fd); return 7; }
        if (split && (info.st_size == 0 || (!parts.empty() && info.st_size > initial.st_size) ||
            (parts.size() > 1 && parts.back().info.st_size != initial.st_size))) { close(fd); return 6; }
        try { parts.push_back({fd, info, total, "", false}); } catch (...) { close(fd); throw; }
        if (parts.size() == 1) initial = info;
        total += (uint64_t)info.st_size;
        return 0;
    }
    bool unchanged() const {
        for (const auto &part: parts) {
            struct stat now, named;
            if (fstat(part.fd, &now) != 0 || !same(part.info, now) ||
                (part.checkPath && (lstat(part.path.c_str(), &named) != 0 || !same(part.info, named)))) return false;
        }
        return true;
    }
    Z7_COM7F_IMF(Read(void *data, UInt32 size, UInt32 *processed)) override {
        if (processed) *processed = 0;
        if (!size || position >= total) return S_OK;
        if (position < parts[cursor].start) cursor = 0;
        while (cursor + 1 < parts.size() && position >= parts[cursor + 1].start) ++cursor;
        const auto &part = parts[cursor];
        uint64_t offset = position - part.start;
        UInt32 request = (UInt32)std::min((uint64_t)size, (uint64_t)part.info.st_size - offset);
        ssize_t count;
        do { count = pread(part.fd, data, request, (off_t)offset); } while (count < 0 && errno == EINTR);
        if (count <= 0) return E_FAIL;
        position += (uint64_t)count;
        if (processed) *processed = (UInt32)count;
        return S_OK;
    }
    Z7_COM7F_IMF(Seek(Int64 offset, UInt32 origin, UInt64 *result)) override {
        if (origin > 2) return E_INVALIDARG;
        int64_t base = origin == 0 ? 0 : (int64_t)(origin == 1 ? position : total);
        if (offset == INT64_MIN || (offset < 0 && base < -offset) || (offset > 0 && base > INT64_MAX - offset)) return E_INVALIDARG;
        position = (uint64_t)(base + offset);
        if (result) *result = position;
        return S_OK;
    }
    uint64_t declaredSize() {
        // 7zFormat.txt: 32-byte signature/start header. Only trust offsets with a valid CRC.
        unsigned char header[32]; UInt32 have = 0;
        uint64_t saved = position; size_t savedCursor = cursor;
        position = 0; cursor = 0;
        while (have < sizeof(header)) {
            UInt32 received = 0;
            if (Read(header + have, (UInt32)sizeof(header) - have, &received) != S_OK || !received) break;
            have += received;
        }
        position = saved; cursor = savedCursor;
        if (have != sizeof(header) || memcmp(header, "7z\xBC\xAF\x27\x1C", 6) || header[6] != 0) return 0;
        uint32_t crc = 0xFFFFFFFFU;
        for (unsigned i = 12; i < sizeof(header); ++i) {
            crc ^= header[i];
            for (unsigned bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ (0xEDB88320U & (0U - (crc & 1U)));
        }
        uint32_t expectedCRC = (uint32_t)header[8] | (uint32_t)header[9] << 8 | (uint32_t)header[10] << 16 | (uint32_t)header[11] << 24;
        if (~crc != expectedCRC) return 0;
        auto little = [](const unsigned char *bytes) { uint64_t result = 0; for (unsigned i = 0; i < 8; ++i) result |= (uint64_t)bytes[i] << (i * 8); return result; };
        uint64_t offset = little(header + 12), size = little(header + 20);
        if (offset > UINT64_MAX - 32 || size > UINT64_MAX - 32 - offset) return 0;
        return 32 + offset + size;
    }
};

class OpenCallback final: public IArchiveOpenCallback, public ICryptoGetTextPassword, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(IArchiveOpenCallback, ICryptoGetTextPassword)
public:
    bool defined = false, requested = false;
    UString password;
};
Z7_COM7F_IMF(OpenCallback::SetTotal(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(OpenCallback::SetCompleted(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(OpenCallback::CryptoGetTextPassword(BSTR *value)) {
    requested = true;
    if (!defined) return E_ABORT;
    return StringToBstr(password, value);
}

struct AuditDigest {
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> data = {}, properties = {};
};
struct Session {
    bool audited = false;
    uint64_t auditBytes = 0;
    std::vector<AuditDigest> audit;
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> archiveProperties = {};
    uint32_t editFormat = 0;
    void *library = nullptr;
    CMyComPtr<IInArchive> archive;
    CMyComPtr<IInStream> source;
    CMyComPtr<IArchiveOpenCallback> callback;
    SourceStream *stream = nullptr;
    OpenCallback *openCallback = nullptr;
    ~Session() {
        if (archive) archive->Close();
        archive.Release(); callback.Release(); source.Release();
        if (library) dlclose(library);
    }
};

static void *openArchives(const char *library, const char *const *paths, uint32_t count, bool split, const char *password, int *error,
                          int *descriptors = nullptr, const SevenZipInputSource *sources = nullptr, const GUID *format = &CLSID_SevenZip) {
    *error = 8;
    try {
        std::unique_ptr<Session> session(new Session());
        session->library = dlopen(library, RTLD_NOW | RTLD_LOCAL);
        if (!session->library) { *error = 1; return nullptr; }
        typedef HRESULT (*Create)(const GUID *, const GUID *, void **);
        auto create = (Create)dlsym(session->library, "CreateObject");
        if (!create || create(format, &IID_IInArchive, (void **)&session->archive) != S_OK) { *error = 1; return nullptr; }
        if ((!paths && (!descriptors || !sources)) || !count || count > 1024 || (!split && count != 1)) { *error = 7; return nullptr; }
        if (split || descriptors) {
            const uint32_t needed = count + 64U;
            // Only this short-lived helper's soft limit changes; the host/system limit is untouched.
            struct rlimit limit;
            if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < needed) {
                limit.rlim_cur = std::min(limit.rlim_max, (rlim_t)needed);
                if (limit.rlim_cur < needed || setrlimit(RLIMIT_NOFILE, &limit) != 0) { *error = 7; return nullptr; }
            }
        }
        session->stream = new SourceStream(); session->source = session->stream;
        for (uint32_t i = 0; i < count; ++i) {
            if (paths && !paths[i]) { *error = 6; return nullptr; }
            int failure = descriptors ? session->stream->appendDescriptor(descriptors[i], sources[i], split) : session->stream->append(paths[i], split);
            if (failure) { *error = failure; return nullptr; }
        }
        session->openCallback = new OpenCallback(); session->callback = session->openCallback;
        if (password) {
            session->openCallback->defined = true;
            if (!ConvertUTF8ToUnicode(AString(password), session->openCallback->password)) { *error = 6; return nullptr; }
        }
        if (split) {
            uint64_t expected = session->stream->declaredSize();
            if (!session->stream->unchanged()) { *error = 9; return nullptr; }
            if (expected && expected != session->stream->total) { *error = expected > session->stream->total ? 13 : 12; return nullptr; }
        }
        UInt64 scan = 8 * 1024 * 1024;
        if (session->archive->Open(session->source, &scan, session->callback) != S_OK) {
            *error = !session->stream->unchanged() ? 9 : (session->openCallback->requested ? (password ? 4 : 3) : 5);
            return nullptr;
        }
        if (!session->stream->unchanged()) { *error = 9; return nullptr; }
        if (split) {
            NWindows::NCOM::CPropVariant physical, offset;
            if (session->archive->GetArchiveProperty(kpidPhySize, &physical) != S_OK || physical.vt != VT_UI8 ||
                session->archive->GetArchiveProperty(kpidOffset, &offset) != S_OK || (offset.vt != VT_EMPTY && offset.vt != VT_UI8)) { *error = 6; return nullptr; }
            uint64_t start = offset.vt == VT_UI8 ? offset.uhVal.QuadPart : 0;
            if (start > session->stream->total || physical.uhVal.QuadPart != session->stream->total - start) { *error = 12; return nullptr; }
        }
        *error = 0; return session.release();
    } catch (...) { return nullptr; }
}

extern "C" void *SevenZipOpen(const char *library, const char *path, const char *password, int *error) {
    return openArchives(library, &path, 1, false, password, error);
}
extern "C" void *SevenZipOpenVolumes(const char *library, const char *const *paths, uint32_t count, const char *password, int *error) {
    return openArchives(library, paths, count, true, password, error);
}

extern "C" void *SevenZipOpenDescriptors(const char *library, int *descriptors, const SevenZipInputSource *sources,
                                         uint32_t count, int split, const char *password, int *error) {
    return openArchives(library, nullptr, count, split != 0, password, error, descriptors, sources);
}

static bool property(IInArchive *archive, UInt32 index, PROPID id, NWindows::NCOM::CPropVariant &value) {
    return archive->GetProperty(index, id, &value) == S_OK;
}
static int metadata(IInArchive *archive, UInt32 i, AString &utf8, UInt64 &bytes, int &kind, bool &isEncrypted, SevenZipEntryMetadata *extra = nullptr) {
    NWindows::NCOM::CPropVariant path, size, directory, encrypted, symbolic, hard, attributes, posix;
    if (!property(archive, i, kpidPath, path) || path.vt != VT_BSTR ||
        !property(archive, i, kpidSize, size) || !property(archive, i, kpidIsDir, directory) ||
        !property(archive, i, kpidEncrypted, encrypted) || !property(archive, i, kpidSymLink, symbolic) ||
        !property(archive, i, kpidHardLink, hard) || !property(archive, i, kpidAttrib, attributes) ||
        !property(archive, i, kpidPosixAttrib, posix)) return 6;
    UString wide; if (path.bstrVal) wide.SetFrom(path.bstrVal, SysStringLen(path.bstrVal));
    ConvertUnicodeToUTF8(wide, utf8);
    bytes = size.vt == VT_UI8 ? size.uhVal.QuadPart : (size.vt == VT_UI4 ? size.ulVal : 0);
    if ((size.vt != VT_EMPTY && size.vt != VT_UI8 && size.vt != VT_UI4) || bytes > INT64_MAX) return 6;
    kind = directory.vt == VT_BOOL && directory.boolVal ? 1 : 0;
    UInt32 mode = posix.vt == VT_UI4 ? posix.ulVal : (attributes.vt == VT_UI4 ? attributes.ulVal >> 16 : 0);
    if ((symbolic.vt == VT_BSTR && SysStringLen(symbolic.bstrVal)) || (mode & S_IFMT) == S_IFLNK) kind = 2;
    else if (hard.vt == VT_BSTR && SysStringLen(hard.bstrVal)) kind = 3;
    else if ((mode & S_IFMT) && (mode & S_IFMT) != S_IFREG && (mode & S_IFMT) != S_IFDIR) kind = 4;
    isEncrypted = encrypted.vt == VT_BOOL && encrypted.boolVal;
    if (extra) {
        NWindows::NCOM::CPropVariant modified;
        if (!property(archive, i, kpidMTime, modified) || (modified.vt != VT_EMPTY && modified.vt != VT_FILETIME) ||
            (posix.vt != VT_EMPTY && posix.vt != VT_UI4) || (attributes.vt != VT_EMPTY && attributes.vt != VT_UI4)) return 6;
        *extra = {};
        if (modified.vt == VT_FILETIME) {
            const uint64_t ticks = ((uint64_t)modified.filetime.dwHighDateTime << 32) | modified.filetime.dwLowDateTime;
            extra->hasModifiedTime = 1;
            extra->modifiedSeconds = (int64_t)(ticks / 10000000ULL) - 11644473600LL;
            extra->modifiedNanos = (uint32_t)(ticks % 10000000ULL) * 100;
        }
        // 7z stores Unix mode in the high word with FILE_ATTRIBUTE_UNIX_EXTENSION.
        // Do not mistake an ordinary Windows attribute word for a Unix mode.
        if (posix.vt == VT_UI4 || (attributes.vt == VT_UI4 && (attributes.ulVal & 0x8000))) {
            extra->hasPermissions = 1;
            extra->permissions = mode & 0777; // Never restore setuid/setgid/sticky or ownership.
        }
    }
    return 0;
}
extern "C" int SevenZipList(void *handle, uint32_t maximum, void *context, SevenZipItemCallback callback) {
    uint32_t total = 0;
    return SevenZipListPage(handle, maximum, 0, UINT32_MAX, context, callback, &total);
}
extern "C" int SevenZipListPage(void *handle, uint32_t maximum, uint32_t offset, uint32_t pageSize,
                                void *context, SevenZipItemCallback callback, uint32_t *total) {
    auto session = (Session *)handle;
    try {
        if (!session->stream->unchanged()) return 9;
        UInt32 count = 0;
        if (session->archive->GetNumberOfItems(&count) != S_OK) return 6;
        if (count > maximum) return 7;
        if (offset > count || !pageSize) return 6;
        *total = count;
        for (UInt32 i = offset; i < count && i - offset < pageSize; ++i) {
            AString utf8; UInt64 bytes = 0; int kind = 0; bool encrypted = false;
            SevenZipEntryMetadata extra = {};
            int error = metadata(session->archive, i, utf8, bytes, kind, encrypted, &extra);
            if (error) return error;
            int accepted = callback(context, i, utf8.Ptr(), utf8.Len(), kind, bytes, encrypted, &extra);
            if (!accepted) return 7;
            if (accepted == 2) break;
        }
        return session->stream->unchanged() ? 0 : 9;
    } catch (...) { return 8; }
}
extern "C" SevenZipSourceIdentity SevenZipIdentity(void *handle) {
    auto &info = ((Session *)handle)->stream->initial;
    return {(uint64_t)info.st_dev, (uint64_t)info.st_ino, ((Session *)handle)->stream->total};
}
extern "C" void *SevenZipOpenEditDescriptor(const char *library, int *descriptor, const SevenZipInputSource *source,
                                             uint32_t format, const char *password, int *error) {
    if (!error) return nullptr;
    if (!descriptor || !source || (format != 1 && format != 7)) { *error = 6; return nullptr; }
    EditLocale locale(format == 1);
    if (!locale.valid()) { *error = 8; return nullptr; }
    auto session = (Session *)openArchives(library, nullptr, 1, false, password, error, descriptor, source,
                                         format == 1 ? &CLSID_Zip : &CLSID_SevenZip);
    if (session) session->editFormat = format;
    return session;
}
extern "C" int SevenZipHeaderPasswordRequested(void *handle) { return ((Session *)handle)->openCallback->requested; }
extern "C" void SevenZipClose(void *handle) { delete (Session *)handle; }

class BoundedOutput final: public ISequentialOutStream, public CMyUnknownImp {
    Z7_COM_UNKNOWN_IMP_1(ISequentialOutStream)
public:
    uint64_t count = 0, maximum;
    bool failed = false;
    int error = 0;
    void *context;
    SevenZipWriteCallback callback;
    BoundedOutput(uint64_t limit, void *ctx, SevenZipWriteCallback write): maximum(limit), context(ctx), callback(write) {}
    Z7_COM7F_IMF(Write(const void *data, UInt32 size, UInt32 *processed)) override {
        if (processed) *processed = 0;
        if (failed) return E_ABORT;
        if (size > maximum - count) { failed = true; error = 7; return E_ABORT; }
        if (size && !callback(context, data, size)) { failed = true; error = 10; return E_ABORT; }
        count += size;
        if (processed) *processed = size;
        return S_OK;
    }
};

class ExtractCallback final: public IArchiveExtractCallback, public ICryptoGetTextPassword, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(IProgress)
public:
    UInt32 selected;
    int operationResult = -1;
    bool selectedStream = false, passwordRequested = false;
    OpenCallback *credentials;
    CMyComPtr<ISequentialOutStream> output;
};
Z7_COM7F_IMF(ExtractCallback::SetTotal(UInt64)) { return S_OK; }
Z7_COM7F_IMF(ExtractCallback::SetCompleted(const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(ExtractCallback::GetStream(UInt32 index, ISequentialOutStream **stream, Int32 mode)) {
    *stream = nullptr;
    if (mode != NArchive::NExtract::NAskMode::kExtract) return S_OK;
    if (index != selected || selectedStream) return E_ABORT;
    selectedStream = true;
    *stream = output; (*stream)->AddRef(); return S_OK;
}
Z7_COM7F_IMF(ExtractCallback::PrepareOperation(Int32)) { return S_OK; }
Z7_COM7F_IMF(ExtractCallback::SetOperationResult(Int32 result)) { operationResult = result; return S_OK; }
Z7_COM7F_IMF(ExtractCallback::CryptoGetTextPassword(BSTR *value)) {
    passwordRequested = true;
    if (!credentials->defined) return E_ABORT;
    return StringToBstr(credentials->password, value);
}

extern "C" int SevenZipExtract(void *handle, uint32_t index, uint64_t expectedSize, uint64_t maximumBytes,
                               void *context, SevenZipWriteCallback callback, uint64_t *written) {
    *written = 0;
    auto session = (Session *)handle;
    try {
        EditLocale locale(session->editFormat == 1);
        if (!locale.valid()) return 8;
        if (!session->stream->unchanged()) return 9;
        UInt32 count = 0;
        if (session->archive->GetNumberOfItems(&count) != S_OK) return 6;
        if (index >= count) return 6;
        AString path; UInt64 size = 0; int kind = 0; bool encrypted = false;
        int error = metadata(session->archive, index, path, size, kind, encrypted);
        if (error) return error;
        if (kind != 0) return 11;
        if (size != expectedSize) return 6;
        if (size > maximumBytes) return 7;
        auto output = new BoundedOutput(size, context, callback);
        CMyComPtr<ISequentialOutStream> stream(output);
        auto extract = new ExtractCallback();
        CMyComPtr<IArchiveExtractCallback> extractOwner(extract);
        extract->selected = index; extract->credentials = session->openCallback; extract->output = stream;
        HRESULT result = session->archive->Extract(&index, 1, false, extractOwner);
        *written = output->count;
        if (!session->stream->unchanged()) return 9;
        if (output->failed) return output->error;
        if (result != S_OK || extract->operationResult != NArchive::NExtract::NOperationResult::kOK) {
            if (extract->passwordRequested) return session->openCallback->defined ? 4 : 3;
            return 12;
        }
        return extract->selectedStream && output->count == size ? 0 : 12;
    } catch (...) { return 8; }
}


// Each output is an in-memory digest sink. It has no filesystem authority and never
// interprets archive paths or link targets as host names.
class AuditOutput final: public ISequentialOutStream, public CMyUnknownImp {
    Z7_COM_UNKNOWN_IMP_1(ISequentialOutStream)
    CC_SHA256_CTX hash;
public:
    UInt64 count = 0, maximum;
    bool failed = false;
    explicit AuditOutput(UInt64 size): maximum(size) { CC_SHA256_Init(&hash); }
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest() const {
        auto copy = hash; std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> value;
        CC_SHA256_Final(value.data(), &copy); return value;
    }
    Z7_COM7F_IMF(Write(const void *data, UInt32 size, UInt32 *processed)) override {
        if (processed) *processed = 0;
        if (size > maximum - count) { failed = true; return E_ABORT; }
        CC_SHA256_Update(&hash, data, size); count += size;
        if (processed) *processed = size;
        return S_OK;
    }
};
class AuditCallback final: public IArchiveExtractCallback, public ICryptoGetTextPassword, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(IProgress)
public:
    OpenCallback *credentials;
    std::vector<UInt64> sizes;
    std::vector<CMyComPtr<ISequentialOutStream>> streams;
    std::vector<AuditOutput *> outputs;
    std::vector<bool> completed;
    uint32_t current = UINT32_MAX;
    uint64_t maximum;
    bool failed = false, limit = false, passwordRequested = false;
};
Z7_COM7F_IMF(AuditCallback::SetTotal(UInt64 size)) { if (size > maximum) { limit = true; return E_ABORT; } return S_OK; }
Z7_COM7F_IMF(AuditCallback::SetCompleted(const UInt64 *size)) { return size ? SetTotal(*size) : S_OK; }
Z7_COM7F_IMF(AuditCallback::GetStream(UInt32 index, ISequentialOutStream **stream, Int32 mode)) {
    *stream = nullptr;
    if (mode != NArchive::NExtract::NAskMode::kExtract || index >= sizes.size() || outputs[index]) { failed = true; return E_ABORT; }
    auto output = new AuditOutput(sizes[index]); streams[index] = output; outputs[index] = output;
    *stream = output; (*stream)->AddRef(); current = index; return S_OK;
}
Z7_COM7F_IMF(AuditCallback::PrepareOperation(Int32 mode)) {
    if (mode != NArchive::NExtract::NAskMode::kExtract || current >= sizes.size()) { failed = true; return E_ABORT; }
    return S_OK;
}
Z7_COM7F_IMF(AuditCallback::SetOperationResult(Int32 result)) {
    if (current >= sizes.size() || completed[current] || result != NArchive::NExtract::NOperationResult::kOK) { failed = true; return E_ABORT; }
    completed[current] = true; return S_OK;
}
Z7_COM7F_IMF(AuditCallback::CryptoGetTextPassword(BSTR *value)) {
    passwordRequested = true;
    return credentials->defined ? StringToBstr(credentials->password, value) : E_ABORT;
}
static bool auditProperty(CC_SHA256_CTX &hash, PROPID id, const PROPVARIANT &value, uint64_t &propertyBytes) {
    // A ZIP NTFS timestamp extra stores all three time slots. The SDK writes zero
    // for an unspecified creation/access time, then reads that sentinel as FILETIME
    // rather than VT_EMPTY. Compare their logical "not set" meaning, preserving
    // every nonzero time value and retaining modification-time precision.
    const bool missingTime = (id == kpidCTime || id == kpidATime) && value.vt == VT_FILETIME &&
        !value.filetime.dwHighDateTime && !value.filetime.dwLowDateTime;
    const VARTYPE type = missingTime ? VT_EMPTY : value.vt;
    CC_SHA256_Update(&hash, &id, sizeof(id)); CC_SHA256_Update(&hash, &type, sizeof(type));
    const void *bytes = nullptr; size_t length = 0;
    switch (type) {
        case VT_EMPTY: break;
        case VT_BOOL: bytes = &value.boolVal; length = sizeof(value.boolVal); break;
        case VT_UI4: bytes = &value.ulVal; length = sizeof(value.ulVal); break;
        case VT_UI8: bytes = &value.uhVal; length = sizeof(value.uhVal); break;
        case VT_FILETIME: bytes = &value.filetime; length = sizeof(value.filetime); break;
        case VT_BSTR: bytes = value.bstrVal; length = value.bstrVal ? (size_t)SysStringLen(value.bstrVal) * sizeof(*value.bstrVal) : 0; break;
        default: return false;
    }
    if (length > 1048576 || length > 268435456ULL - propertyBytes) return false;
    propertyBytes += length;
    uint64_t size = length; CC_SHA256_Update(&hash, &size, sizeof(size));
    if (length) CC_SHA256_Update(&hash, bytes, (CC_LONG)length);
    return true;
}
extern "C" int SevenZipAuditPage(void *handle, uint32_t offset, uint32_t pageSize, uint64_t maximumBytes,
                                 void *context, SevenZipAuditCallback callback, uint32_t *total, unsigned char *archiveProperties) {
    auto session = (Session *)handle;
    if (!session || !session->editFormat || !callback || !total || !archiveProperties || !pageSize || pageSize > 256 || !maximumBytes || maximumBytes > 20000000000ULL) return 6;
    try {
        EditLocale locale(session->editFormat == 1); if (!locale.valid()) return 8;
        if (!session->stream->unchanged()) return 9;
        UInt32 count = 0;
        if (session->archive->GetNumberOfItems(&count) != S_OK) return 6;
        if (count > 100000 || session->stream->total > 8000000000ULL || (session->audited && session->auditBytes > maximumBytes)) return 7;
        if (offset > count) return 6;
        if (!session->audited) {
            auto audit = new AuditCallback(); CMyComPtr<IArchiveExtractCallback> owner(audit);
            audit->credentials = session->openCallback; audit->maximum = maximumBytes + session->stream->total;
            audit->sizes.resize(count); audit->streams.resize(count); audit->outputs.resize(count, nullptr); audit->completed.resize(count, false);
            std::vector<AuditDigest> digests(count); uint64_t bytes = 0, propertyBytes = 0;
            for (UInt32 index = 0; index < count; ++index) {
                AString path; UInt64 size = 0; int kind = 0; bool encrypted = false;
                int error = metadata(session->archive, index, path, size, kind, encrypted); if (error) return error;
                if (size > 8000000000ULL || size > maximumBytes - bytes) return 7;
                audit->sizes[index] = size; bytes += size;
                CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
                for (PROPID id: {kpidCTime, kpidATime, kpidMTime, kpidAttrib, kpidPosixAttrib, kpidComment, kpidSymLink, kpidHardLink}) {
                    NWindows::NCOM::CPropVariant value;
                    if (!property(session->archive, index, id, value) || !auditProperty(hash, id, value, propertyBytes)) return 6;
                }
                CC_SHA256_Final(digests[index].properties.data(), &hash);
            }
            CC_SHA256_CTX hash; CC_SHA256_Init(&hash); NWindows::NCOM::CPropVariant comment;
            if (session->archive->GetArchiveProperty(kpidComment, &comment) != S_OK || !auditProperty(hash, kpidComment, comment, propertyBytes)) return 6;
            std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> archiveDigest; CC_SHA256_Final(archiveDigest.data(), &hash);
            HRESULT result = count ? session->archive->Extract(nullptr, (UInt32)-1, false, owner) : S_OK;
            if (!session->stream->unchanged()) return 9;
            if (audit->limit) return 7;
            if (result != S_OK || audit->failed) return audit->passwordRequested ? (session->openCallback->defined ? 4 : 3) : 12;
            for (UInt32 index = 0; index < count; ++index) {
                auto output = audit->outputs[index];
                if (!audit->completed[index] || !output || output->failed || output->count != audit->sizes[index]) return 12;
                digests[index].data = output->digest();
            }
            session->audit = std::move(digests); session->auditBytes = bytes; session->archiveProperties = archiveDigest; session->audited = true;
        }
        *total = count; memcpy(archiveProperties, session->archiveProperties.data(), CC_SHA256_DIGEST_LENGTH);
        uint32_t end = std::min(count, offset + pageSize);
        for (uint32_t index = offset; index < end; ++index) {
            const auto &digest = session->audit[index];
            if (!callback(context, index, digest.data.data(), digest.properties.data())) return 6;
        }
        return session->stream->unchanged() ? 0 : 9;
    } catch (...) { return 8; }
}

// Creation reads only planned regular files/directories, without following any path symlinks.
static int openSource(const char *path) {
    if (!path || path[0] != '/') return -1;
    int current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (current < 0) return -1;
    const char *part = path + 1;
    while (*part) {
        const char *end = strchr(part, '/');
        size_t size = end ? (size_t)(end - part) : strlen(part);
        if (!size || (size == 1 && part[0] == '.') || (size == 2 && part[0] == '.' && part[1] == '.')) { close(current); return -1; }
        std::string name(part, size);
        int next = openat(current, name.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (end ? O_DIRECTORY : 0));
        close(current); current = next;
        if (current < 0 || !end) return current;
        part = end + 1;
    }
    close(current); return -1;
}
static bool matchesCreateItem(const SevenZipCreateItem &item, int fd) {
    struct stat info;
    return (fcntl(fd, F_GETFL) & O_ACCMODE) == O_RDONLY && fstat(fd, &info) == 0 && (uint64_t)info.st_dev == item.device && (uint64_t)info.st_ino == item.inode &&
        (uint32_t)info.st_mode == item.mode && (item.directory ? S_ISDIR(info.st_mode) : S_ISREG(info.st_mode)) &&
        (item.directory || (info.st_size >= 0 && (uint64_t)info.st_size == item.size)) &&
        info.st_mtimespec.tv_sec == item.modifiedSeconds && info.st_mtimespec.tv_nsec == item.modifiedNanos &&
        info.st_ctimespec.tv_sec == item.changedSeconds && info.st_ctimespec.tv_nsec == item.changedNanos;
}
class CreateInput final: public ISequentialInStream, public CMyUnknownImp {
    Z7_COM_UNKNOWN_IMP_1(ISequentialInStream)
    int fd;
    SevenZipCreateItem item;
    uint64_t readBytes = 0;
    bool *changed;
public:
    CreateInput(int descriptor, const SevenZipCreateItem &entry, bool *flag): fd(descriptor), item(entry), changed(flag) {}
    ~CreateInput() { if (!matchesCreateItem(item, fd) || readBytes != item.size) *changed = true; close(fd); }
    Z7_COM7F_IMF(Read(void *data, UInt32 size, UInt32 *processed)) override {
        if (processed) *processed = 0;
        if (!matchesCreateItem(item, fd)) { *changed = true; return E_ABORT; }
        ssize_t count;
        do { count = pread(fd, data, size, (off_t)readBytes); } while (count < 0 && errno == EINTR);
        if (count < 0 || (uint64_t)count > item.size - readBytes) return E_FAIL;
        readBytes += count;
        if (count == 0 && size && readBytes != item.size) { *changed = true; return E_ABORT; }
        if (processed) *processed = (UInt32)count;
        return S_OK;
    }
};
class CreateOutput final: public IOutStream, public CMyUnknownImp {
    Z7_COM_UNKNOWN_IMP_2(IOutStream, ISequentialOutStream)
    int fd;
    bool framed;
    std::mutex mutex;
    uint64_t position = 0, length = 0;
    bool bytes(const void *data, size_t size) {
        size_t total = 0;
        while (total < size) {
            ssize_t count = write(fd, (const char *)data + total, size - total);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) return false;
            total += (size_t)count;
        }
        return true;
    }
    bool record(unsigned char type, uint64_t offset, uint64_t size, const void *data) {
        unsigned char header[17]; header[0] = type;
        for (unsigned i = 0; i < 8; ++i) { header[1 + i] = (unsigned char)(offset >> (56 - i * 8)); header[9 + i] = (unsigned char)(size >> (56 - i * 8)); }
        return bytes(header, sizeof(header)) && (!size || bytes(data, (size_t)size));
    }
public:
    CreateOutput(int descriptor, bool useFrames): fd(descriptor), framed(useFrames) {}
    Z7_COM7F_IMF(Write(const void *data, UInt32 size, UInt32 *processed)) override {
        std::lock_guard<std::mutex> guard(mutex);
        if (processed) *processed = 0;
        if (size > 8000000000ULL - position) return E_FAIL;
        UInt32 total = 0;
        while (total < size) {
            UInt32 count = std::min((UInt32)65536, size - total);
            const char *chunk = (const char *)data + total;
            if (!(framed ? record(0, position, count, chunk) : bytes(chunk, count))) return E_FAIL;
            total += count; position += count; length = std::max(length, position);
        }
        if (processed) *processed = total;
        return S_OK;
    }
    Z7_COM7F_IMF(Seek(Int64 offset, UInt32 origin, UInt64 *result)) override {
        std::lock_guard<std::mutex> guard(mutex);
        if (origin > 2) return E_INVALIDARG;
        int64_t base = origin == 0 ? 0 : (int64_t)(origin == 1 ? position : length);
        if (offset == INT64_MIN || (offset < 0 && base < -offset) || (offset > 0 && base > INT64_MAX - offset)) return E_INVALIDARG;
        uint64_t target = (uint64_t)(base + offset);
        if (target > 8000000000ULL || (!framed && lseek(fd, (off_t)target, SEEK_SET) < 0)) return E_FAIL;
        position = target;
        if (result) *result = position;
        return S_OK;
    }
    Z7_COM7F_IMF(SetSize(UInt64 size)) override {
        std::lock_guard<std::mutex> guard(mutex);
        if (size > 8000000000ULL || !(framed ? record(1, size, 0, nullptr) : ftruncate(fd, size) == 0)) return E_FAIL;
        length = size; return S_OK;
    }
    bool finish() { std::lock_guard<std::mutex> guard(mutex); return framed ? record(2, length, 0, nullptr) : fsync(fd) == 0; }
};
class CreateCallback final: public IArchiveUpdateCallback, public ICryptoGetTextPassword2, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(IArchiveUpdateCallback, ICryptoGetTextPassword2)
    Z7_IFACE_COM7_IMP(IProgress)
public:
    const SevenZipCreateItem *items;
    uint32_t count;
    bool defined = false, changed = false, failed = false;
    UString password;
    SevenZipCreateInputCallback inputCallback = nullptr;
    void *inputContext = nullptr;
};
Z7_COM7F_IMF(CreateCallback::SetTotal(UInt64)) { return S_OK; }
Z7_COM7F_IMF(CreateCallback::SetCompleted(const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(CreateCallback::GetUpdateItemInfo(UInt32 index, Int32 *data, Int32 *properties, UInt32 *oldIndex)) {
    if (index >= count) return E_INVALIDARG;
    if (data) *data = 1;
    if (properties) *properties = 1;
    if (oldIndex) *oldIndex = (UInt32)-1;
    return S_OK;
}
static HRESULT createItemProperty(const SevenZipCreateItem &item, PROPID propertyID, PROPVARIANT *value) {
    NWindows::NCOM::CPropVariant property;
    switch (propertyID) {
        case kpidPath: {
            UString path;
            if (!ConvertUTF8ToUnicode(AString(item.path), path)) return E_INVALIDARG;
            property = path; break;
        }
        case kpidIsDir: property = (item.directory != 0); break;
        case kpidSize: property = (UInt64)item.size; break;
        case kpidIsAnti: property = false; break;
        case kpidPosixAttrib: property = (UInt32)item.mode; break;
        case kpidAttrib: {
            // Match the SDK's Get_WinAttribPosix_From_PosixMode representation.
            UInt32 attributes = 0x8000 | ((item.mode & 0xFFFF) << 16) | (item.directory ? 0x10 : 0x20);
            if (!(item.mode & 0222)) attributes |= 0x01;
            property = attributes; break;
        }
        case kpidMTime: {
            // SDK FILETIME uses 100ns ticks since 1601.
            if (item.modifiedSeconds >= -11644473600LL) {
                uint64_t ticks = ((uint64_t)(item.modifiedSeconds + 11644473600LL)) * 10000000ULL + item.modifiedNanos / 100;
                FILETIME time; time.dwLowDateTime = (UInt32)ticks; time.dwHighDateTime = (UInt32)(ticks >> 32);
                property = time;
            }
            break;
        }
    }
    property.Detach(value); return S_OK;
}
Z7_COM7F_IMF(CreateCallback::GetProperty(UInt32 index, PROPID propertyID, PROPVARIANT *value)) {
    return index < count ? createItemProperty(items[index], propertyID, value) : E_INVALIDARG;
}
Z7_COM7F_IMF(CreateCallback::GetStream(UInt32 index, ISequentialInStream **stream)) {
    if (index >= count) return E_INVALIDARG;
    *stream = nullptr;
    const auto &item = items[index];
    int fd = inputCallback ? inputCallback(inputContext, index) : openSource(item.source);
    if (fd < 0) { changed = true; return E_ABORT; }
    if (!matchesCreateItem(item, fd)) { close(fd); changed = true; return E_ABORT; }
    if (item.directory) { close(fd); return S_OK; }
    CMyComPtr<ISequentialInStream> input = new CreateInput(fd, item, &changed);
    *stream = input.Detach(); return S_OK;
}
Z7_COM7F_IMF(CreateCallback::SetOperationResult(Int32 result)) { if (result != 0) failed = true; return result == 0 ? S_OK : E_FAIL; }
Z7_COM7F_IMF(CreateCallback::CryptoGetTextPassword2(Int32 *isDefined, BSTR *value)) {
    *isDefined = defined ? 1 : 0;
    return StringToBstr(password, value);
}
extern "C" int SevenZipCreate(const char *library, int outputFD, const SevenZipCreateItem *items, uint32_t count,
                              const char *password, int level, int encryptHeader, uint32_t dictionarySize, uint32_t wordSize, uint32_t threads, int framedOutput, SevenZipCreateInputCallback inputCallback, void *inputContext) {
    // The library stays loaded until all COM objects have been released, including exceptions.
    struct Library { void *handle; ~Library() { if (handle) dlclose(handle); } } loaded{dlopen(library, RTLD_NOW | RTLD_LOCAL)};
    if (!loaded.handle) return 1;
    try {
        typedef HRESULT (*Create)(const GUID *, const GUID *, void **);
        auto create = (Create)dlsym(loaded.handle, "CreateObject");
        CMyComPtr<IOutArchive> archive;
        if (!create || create(&CLSID_SevenZip, &IID_IOutArchive, (void **)&archive) != S_OK) return 1;
        CMyComPtr<ISetProperties> properties;
        if (archive->QueryInterface(IID_ISetProperties, (void **)&properties) != S_OK || !properties) return 1;
        const wchar_t *names[] = { L"x", L"he", L"mt", L"0", L"0d", L"0fb" };
        NWindows::NCOM::CPropVariant values[6];
        values[0] = (UInt32)level; values[1] = (encryptHeader != 0); values[2] = (UInt32)threads;
        values[3] = L"LZMA2";
        // ISetProperties interprets numeric d as log2(bytes), not a byte count.
        UInt32 dictionaryLog = 0;
        for (UInt32 size = dictionarySize; size > 1; size >>= 1) ++dictionaryLog;
        values[4] = dictionaryLog; values[5] = (UInt32)wordSize;
        if (properties->SetProperties(names, values, level == 0 ? 3 : 6) != S_OK) return 6;
        CreateCallback *callback = new CreateCallback();
        CMyComPtr<IArchiveUpdateCallback> callbackHolder = callback;
        callback->items = items; callback->count = count; callback->defined = password != nullptr;
        callback->inputCallback = inputCallback; callback->inputContext = inputContext;
        if (password && !ConvertUTF8ToUnicode(AString(password), callback->password)) return 6;
        auto stream = new CreateOutput(outputFD, framedOutput != 0);
        CMyComPtr<ISequentialOutStream> output = stream;
        HRESULT status = archive->UpdateItems(output, count, callbackHolder);
        if (callback->changed) return 9;
        if (status != S_OK || callback->failed) return 10;
        for (uint32_t i = 0; i < count; ++i) {
            int fd = inputCallback ? inputCallback(inputContext, i) : openSource(items[i].source);
            if (fd < 0) return 9;
            bool matches = matchesCreateItem(items[i], fd); close(fd);
            if (!matches) return 9;
        }
        return stream->finish() ? 0 : 10;
    } catch (...) { return 8; }
}

// Test retained data without creating host files. This also validates encrypted data passwords
// before a metadata-only edit can otherwise copy encrypted streams without decrypting them.
class EditTestCallback final: public IArchiveExtractCallback, public ICryptoGetTextPassword, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(IProgress)
public:
    OpenCallback *credentials;
    uint64_t maximum;
    uint32_t completed = 0;
    bool failed = false, limit = false, requestedPassword = false, testing = false;
};
Z7_COM7F_IMF(EditTestCallback::SetTotal(UInt64 value)) { if (value > maximum) { limit = true; return E_ABORT; } return S_OK; }
Z7_COM7F_IMF(EditTestCallback::SetCompleted(const UInt64 *value)) { return value ? SetTotal(*value) : S_OK; }
Z7_COM7F_IMF(EditTestCallback::GetStream(UInt32, ISequentialOutStream **stream, Int32)) { *stream = nullptr; return S_OK; }
Z7_COM7F_IMF(EditTestCallback::PrepareOperation(Int32 mode)) { testing = mode == NArchive::NExtract::NAskMode::kTest; return S_OK; }
Z7_COM7F_IMF(EditTestCallback::SetOperationResult(Int32 result)) {
    if (testing) ++completed;
    if (result != NArchive::NExtract::NOperationResult::kOK) failed = true;
    return S_OK;
}
Z7_COM7F_IMF(EditTestCallback::CryptoGetTextPassword(BSTR *value)) {
    requestedPassword = true;
    return credentials->defined ? StringToBstr(credentials->password, value) : E_ABORT;
}

class EditCallback final: public IArchiveUpdateCallback, public ICryptoGetTextPassword2, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(IArchiveUpdateCallback, ICryptoGetTextPassword2)
    Z7_IFACE_COM7_IMP(IProgress)
public:
    const SevenZipEditItem *items;
    uint32_t count;
    CMyComPtr<IInArchive> source;
    CMyComPtr<IArchiveUpdateCallback> additions;
    OpenCallback *credentials;
    bool encrypt = false, failed = false;
};
Z7_COM7F_IMF(EditCallback::SetTotal(UInt64)) { return S_OK; }
Z7_COM7F_IMF(EditCallback::SetCompleted(const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(EditCallback::GetUpdateItemInfo(UInt32 index, Int32 *data, Int32 *properties, UInt32 *oldIndex)) {
    if (index >= count) return E_INVALIDARG;
    const auto &entry = items[index];
    if (data) *data = entry.addition ? 1 : 0;
    if (properties) *properties = entry.addition || entry.renamedPath ? 1 : 0;
    if (oldIndex) *oldIndex = entry.oldIndex;
    return S_OK;
}
Z7_COM7F_IMF(EditCallback::GetProperty(UInt32 index, PROPID propertyID, PROPVARIANT *value)) {
    if (index >= count) return E_INVALIDARG;
    const auto &entry = items[index];
    if (entry.addition) return additions->GetProperty(index, propertyID, value);
    if (propertyID == kpidPath && entry.renamedPath) {
        UString path;
        if (!ConvertUTF8ToUnicode(AString(entry.renamedPath), path)) return E_INVALIDARG;
        NWindows::NCOM::CPropVariant property(path); property.Detach(value); return S_OK;
    }
    return source->GetProperty(entry.oldIndex, propertyID, value);
}
Z7_COM7F_IMF(EditCallback::GetStream(UInt32 index, ISequentialInStream **stream)) {
    *stream = nullptr;
    if (index >= count || !items[index].addition) return E_INVALIDARG;
    return items[index].syntheticDirectory ? S_OK : additions->GetStream(index, stream);
}
Z7_COM7F_IMF(EditCallback::SetOperationResult(Int32 result)) { if (result != 0) failed = true; return result == 0 ? S_OK : E_FAIL; }
Z7_COM7F_IMF(EditCallback::CryptoGetTextPassword2(Int32 *defined, BSTR *value)) {
    *defined = encrypt ? 1 : 0;
    return StringToBstr(credentials->password, value);
}

static bool editPath(const char *path, std::string &canonical) {
    if (!path) return false;
    size_t length = strnlen(path, 1048577);
    if (!length || length > 1048576 || path[0] == '/' || path[0] == '~' || strchr(path, '\\')) return false;
    if (length >= 2 && path[1] == ':' && ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z'))) return false;
    std::string raw(path, length);
    for (size_t start = 0; start <= length;) {
        size_t end = raw.find('/', start); if (end == std::string::npos) end = length;
        std::string component = raw.substr(start, end - start);
        if (component.empty() || component == "." || component == "..") return false;
        if (end == length) break;
        start = end + 1;
    }
    CFStringRef original = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)path, length, kCFStringEncodingUTF8, false);
    if (!original) return false;
    CFMutableStringRef normalized = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, original); CFRelease(original);
    if (!normalized) return false;
    CFStringNormalize(normalized, kCFStringNormalizationFormC);
    std::vector<char> bytes((size_t)CFStringGetMaximumSizeForEncoding(CFStringGetLength(normalized), kCFStringEncodingUTF8) + 1);
    bool valid = CFStringGetCString(normalized, bytes.data(), bytes.size(), kCFStringEncodingUTF8);
    CFRelease(normalized);
    if (!valid) return false;
    canonical = bytes.data(); return canonical.size() <= 1048576;
}

extern "C" int SevenZipEdit(void *handle, int outputFD, const SevenZipEditItem *items, uint32_t count,
                            int encryptNewData, uint64_t maximumUnpackedBytes,
                            SevenZipCreateInputCallback inputCallback, void *inputContext) {
    auto session = (Session *)handle;
    if (!session || !session->editFormat || (count && !items) || count > 100000 ||
        (encryptNewData != 0 && encryptNewData != 1) || !maximumUnpackedBytes || maximumUnpackedBytes > 20000000000ULL) return 6;
    try {
        EditLocale locale(session->editFormat == 1);
        if (!locale.valid()) return 8;
        if (!session->stream->unchanged()) return 9;
        struct stat outputInfo;
        int outputFlags = fcntl(outputFD, F_GETFL);
        if (outputFlags < 0 || fstat(outputFD, &outputInfo) != 0 || !S_ISREG(outputInfo.st_mode) || outputInfo.st_size ||
            outputInfo.st_nlink != 1 || (outputFlags & O_ACCMODE) != O_WRONLY || (outputFlags & O_APPEND) ||
            lseek(outputFD, 0, SEEK_CUR) != 0 || session->stream->containsIdentity(outputInfo)) return 6;
        if (session->stream->total > 8000000000ULL) return 7;
        UInt32 oldCount = 0;
        if (session->archive->GetNumberOfItems(&oldCount) != S_OK) return 6;
        if (oldCount > 100000) return 7;
        struct Old { AString path; UInt64 size; int kind; bool encrypted; };
        std::vector<Old> old(oldCount);
        uint64_t sourceBytes = 0, resultBytes = 0, pathBytes = 0, sourcePathBytes = 0;
        for (UInt32 i = 0; i < oldCount; ++i) {
            int error = metadata(session->archive, i, old[i].path, old[i].size, old[i].kind, old[i].encrypted);
            if (error) return error;
            sourcePathBytes += old[i].path.Len();
            if (old[i].path.Len() > 1048576 || sourcePathBytes > 268435456) return 7;
            if (old[i].size > 8000000000ULL || old[i].size > maximumUnpackedBytes - sourceBytes) return 7;
            sourceBytes += old[i].size;
        }
        std::set<uint32_t> retained;
        std::set<std::string> paths, files;
        std::vector<std::string> desired(count);
        std::vector<SevenZipCreateItem> added(count);
        std::vector<UInt32> testIndices;
        bool retainedEncrypted = false, fileAdditions = false;
        for (uint32_t i = 0; i < count; ++i) {
            const auto &entry = items[i];
            const char *path = nullptr;
            uint64_t size = 0;
            bool directory = false;
            if (entry.addition) {
                const auto &a = *entry.addition;
                if (entry.oldIndex != UINT32_MAX || entry.renamedPath || a.source ||
                    (entry.syntheticDirectory != 0 && entry.syntheticDirectory != 1) ||
                    (a.directory != 0 && a.directory != 1) || (entry.syntheticDirectory && !a.directory) ||
                    (a.mode & S_IFMT) != (a.directory ? S_IFDIR : S_IFREG) || (a.directory && a.size) ||
                    a.modifiedSeconds < -11644473600LL || a.modifiedSeconds > 100000000000LL || a.modifiedNanos >= 1000000000 ||
                    a.changedSeconds < -11644473600LL || a.changedSeconds > 100000000000LL || a.changedNanos >= 1000000000) return 6;
                added[i] = a; path = a.path; size = a.size; directory = a.directory;
                if (!entry.syntheticDirectory) {
                    if (!inputCallback) return 6;
                    fileAdditions |= !a.directory;
                    int fd = inputCallback(inputContext, i);
                    if (fd < 0) return 9;
                    bool matches = matchesCreateItem(a, fd); close(fd);
                    if (!matches) return 9;
                }
            } else {
                if (entry.syntheticDirectory || entry.oldIndex >= oldCount || !retained.insert(entry.oldIndex).second) return 6;
                const auto &a = old[entry.oldIndex];
                if (memchr(a.path.Ptr(), 0, a.path.Len())) return 6;
                path = entry.renamedPath ? entry.renamedPath : a.path.Ptr(); size = a.size; directory = a.kind == 1;
                retainedEncrypted |= a.encrypted;
                if (!directory) testIndices.push_back(entry.oldIndex);
            }
            if (!editPath(path, desired[i]) || !paths.insert(desired[i]).second) return 6;
            pathBytes += desired[i].size(); if (pathBytes > 268435456) return 7;
            if (!directory) files.insert(desired[i]);
            if (size > 8000000000ULL || size > maximumUnpackedBytes - resultBytes) return 7;
            resultBytes += size;
        }
        for (const auto &path: paths) for (size_t pos = path.find('/'); pos != std::string::npos; pos = path.find('/', pos + 1))
            if (files.count(path.substr(0, pos))) return 6;
        bool headerEncrypted = session->editFormat == 7 && session->openCallback->requested;
        if ((encryptNewData || headerEncrypted || retainedEncrypted) && !session->openCallback->defined) return 3;
        if ((encryptNewData || headerEncrypted) && !session->openCallback->password.Len()) return 6;
        // An encrypted archive cannot silently accept plaintext additions through a default policy.
        if (fileAdditions && (retainedEncrypted || headerEncrypted) && !encryptNewData) return 6;
        if (!testIndices.empty()) {
            std::sort(testIndices.begin(), testIndices.end());
            auto tester = new EditTestCallback(); CMyComPtr<IArchiveExtractCallback> owner(tester);
            tester->credentials = session->openCallback; tester->maximum = sourceBytes + session->stream->total;
            HRESULT status = session->archive->Extract(testIndices.data(), (UInt32)testIndices.size(), 1, owner);
            if (!session->stream->unchanged()) return 9;
            if (tester->limit) return 7;
            if (status != S_OK || tester->failed || tester->completed != testIndices.size())
                return tester->requestedPassword ? (session->openCallback->defined ? 4 : 3) : 12;
        }
        CMyComPtr<IOutArchive> writer;
        if (session->archive->QueryInterface(IID_IOutArchive, (void **)&writer) != S_OK || !writer) return 11;
        CMyComPtr<ISetProperties> properties;
        if (writer->QueryInterface(IID_ISetProperties, (void **)&properties) != S_OK || !properties) return 11;
        const wchar_t *names[] = {L"x", L"mt", session->editFormat == 7 ? L"he" : L"em"};
        NWindows::NCOM::CPropVariant values[3]; values[0] = (UInt32)5; values[1] = (UInt32)2;
        if (session->editFormat == 7) values[2] = headerEncrypted;
        else values[2] = L"AES256";
        if (properties->SetProperties(names, values, session->editFormat == 7 || encryptNewData ? 3 : 2) != S_OK) return 6;
        auto inputs = new CreateCallback(); CMyComPtr<IArchiveUpdateCallback> inputOwner(inputs);
        inputs->items = added.data(); inputs->count = count; inputs->inputCallback = inputCallback; inputs->inputContext = inputContext;
        auto edit = new EditCallback(); CMyComPtr<IArchiveUpdateCallback> owner(edit);
        edit->items = items; edit->count = count; edit->source = session->archive; edit->additions = inputOwner;
        edit->credentials = session->openCallback;
        edit->encrypt = session->editFormat == 1 ? (fileAdditions && encryptNewData) : (encryptNewData || retainedEncrypted || headerEncrypted);
        auto stream = new CreateOutput(outputFD, false); CMyComPtr<ISequentialOutStream> output(stream);
        if (!session->stream->unchanged()) return 9;
        HRESULT status = writer->UpdateItems(output, count, owner);
        if (!session->stream->unchanged() || inputs->changed) return 9;
        if (status != S_OK || inputs->failed || edit->failed) return 10;
        for (uint32_t i = 0; i < count; ++i) if (items[i].addition && !items[i].syntheticDirectory) {
            int fd = inputCallback(inputContext, i); if (fd < 0) return 9;
            bool matches = matchesCreateItem(*items[i].addition, fd); close(fd);
            if (!matches) return 9;
        }
        struct stat finalOutput;
        if (!session->stream->unchanged() || fstat(outputFD, &finalOutput) != 0 || finalOutput.st_dev != outputInfo.st_dev ||
            finalOutput.st_ino != outputInfo.st_ino || finalOutput.st_nlink != 1) return 9;
        return stream->finish() ? 0 : 10;
    } catch (...) { return 8; }
}
