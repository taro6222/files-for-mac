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

Z7_DEFINE_GUID(CLSID_SevenZip, 0x23170f69, 0x40c1, 0x278a, 0x10, 0, 0, 1, 0x10, 7, 0, 0);

class SourceStream final: public IInStream, public CMyUnknownImp {
    Z7_COM_UNKNOWN_IMP_2(IInStream, ISequentialInStream)
    int fd;
public:
    struct stat initial;
    SourceStream(int descriptor, const struct stat &snapshot): fd(descriptor), initial(snapshot) {}
    ~SourceStream() { close(fd); }
    bool unchanged() const {
        struct stat now;
        return fstat(fd, &now) == 0 && now.st_size == initial.st_size &&
            now.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec && now.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec &&
            now.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec && now.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec;
    }
    Z7_COM7F_IMF(Read(void *data, UInt32 size, UInt32 *processed)) override {
        if (processed) *processed = 0;
        ssize_t count;
        do { count = read(fd, data, size); } while (count < 0 && errno == EINTR);
        if (count < 0) return E_FAIL;
        if (processed) *processed = (UInt32)count;
        return S_OK;
    }
    Z7_COM7F_IMF(Seek(Int64 offset, UInt32 origin, UInt64 *position)) override {
        if (origin > 2) return E_INVALIDARG;
        off_t value = lseek(fd, offset, origin == 0 ? SEEK_SET : (origin == 1 ? SEEK_CUR : SEEK_END));
        if (value < 0) return E_FAIL;
        if (position) *position = (UInt64)value;
        return S_OK;
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

struct Session {
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

extern "C" void *SevenZipOpen(const char *library, const char *path, const char *password, int *error) {
    *error = 8;
    try {
        std::unique_ptr<Session> session(new Session());
        session->library = dlopen(library, RTLD_NOW | RTLD_LOCAL);
        if (!session->library) { *error = 1; return nullptr; }
        typedef HRESULT (*Create)(const GUID *, const GUID *, void **);
        auto create = (Create)dlsym(session->library, "CreateObject");
        if (!create || create(&CLSID_SevenZip, &IID_IInArchive, (void **)&session->archive) != S_OK) { *error = 1; return nullptr; }
        int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0) { *error = 2; return nullptr; }
        struct stat info;
        if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0) { close(fd); *error = 2; return nullptr; }
        session->stream = new SourceStream(fd, info); session->source = session->stream;
        session->openCallback = new OpenCallback(); session->callback = session->openCallback;
        if (password) {
            session->openCallback->defined = true;
            if (!ConvertUTF8ToUnicode(AString(password), session->openCallback->password)) { *error = 6; return nullptr; }
        }
        UInt64 scan = 8 * 1024 * 1024;
        if (session->archive->Open(session->source, &scan, session->callback) != S_OK) {
            *error = session->openCallback->requested ? (password ? 4 : 3) : 5;
            return nullptr;
        }
        if (!session->stream->unchanged()) { *error = 9; return nullptr; }
        *error = 0; return session.release();
    } catch (...) { return nullptr; }
}

static bool property(IInArchive *archive, UInt32 index, PROPID id, NWindows::NCOM::CPropVariant &value) {
    return archive->GetProperty(index, id, &value) == S_OK;
}
static int metadata(IInArchive *archive, UInt32 i, AString &utf8, UInt64 &bytes, int &kind, bool &isEncrypted) {
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
    return 0;
}
extern "C" int SevenZipList(void *handle, uint32_t maximum, void *context, SevenZipItemCallback callback) {
    auto session = (Session *)handle;
    try {
        if (!session->stream->unchanged()) return 9;
        UInt32 count = 0;
        if (session->archive->GetNumberOfItems(&count) != S_OK) return 6;
        if (count > maximum) return 7;
        for (UInt32 i = 0; i < count; ++i) {
            AString utf8; UInt64 bytes = 0; int kind = 0; bool encrypted = false;
            int error = metadata(session->archive, i, utf8, bytes, kind, encrypted);
            if (error) return error;
            if (!callback(context, i, utf8.Ptr(), utf8.Len(), kind, bytes, encrypted)) return 7;
        }
        return session->stream->unchanged() ? 0 : 9;
    } catch (...) { return 8; }
}
extern "C" SevenZipSourceIdentity SevenZipIdentity(void *handle) {
    auto &info = ((Session *)handle)->stream->initial;
    return {(uint64_t)info.st_dev, (uint64_t)info.st_ino, (uint64_t)info.st_size};
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
