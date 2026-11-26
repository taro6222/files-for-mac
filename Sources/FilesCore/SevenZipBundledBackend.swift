import Foundation
import CryptoKit
import Security
import Darwin

public enum SevenZipBundleError: Error, Sendable, Equatable {
    case unavailable, invalidLayout, invalidManifest, invalidSignature, changedBundle, incompatibleArchitecture
}

extension SevenZipArchiveProvider {
    /// Resolve sealed private code without executing a shell, Python, or code from PATH.
    public static func bundled(in app: URL = Bundle.main.bundleURL, timeout: TimeInterval = 300,
                               maximumPhysicalFootprintBytes: UInt64 = Self.defaultMaximumPhysicalFootprintBytes) async throws -> Self {
        guard timeout.isFinite, timeout > 0, timeout <= 86_400, maximumPhysicalFootprintBytes > 0 else { throw SevenZipWorkerError.invalidConfiguration }
        let cancellation = SevenZipBundleCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        let locations = try SevenZipBundleVerifier.verify(app, check: cancellation.check)
                        return Self(verifiedExecutable: locations.worker, library: locations.library, bundle: app, identity: locations.identity, timeout: timeout,
                                    maximumPhysicalFootprintBytes: maximumPhysicalFootprintBytes)
                    })
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}

private final class SevenZipBundleCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

enum SevenZipBundleVerifier {
    static let resource = "Contents/Resources/ThirdParty/7zip"
    static let workerPath = "Contents/Helpers/SevenZipWorker", libraryPath = "Contents/Helpers/7z.so"
    static let sdkVersion = "26.06"
    static let sourceSHA256 = "a4e374c8f864f51df48c2cfd0e1413ec3b2ea030deae852d6a655402ebb61ac4"
    static let sdkChanges: [String: String] = [
        "identifier": "zip-aes-utf8-bounded-password-v1",
        "CPP/7zip/Archive/Zip/ZipHandlerOut.cpp:original": "7e5dbd19afbdb61998f9e10e86f88452f4ce9a48790f3ad634ac3b74a08f66fe",
        "CPP/7zip/Archive/Zip/ZipHandlerOut.cpp:modified": "8a6a2853d3177b34cab032a2f22a208f15f69cd97a7d00b6e0e3b783953ef08e",
        "CPP/7zip/Crypto/WzAes.h:original": "6e5686fb017e2e06e967d135ba9deca19bcdfb1bb5ff16888c549a611a2715de",
        "CPP/7zip/Crypto/WzAes.h:modified": "a5928d541ee78884a26abefb142fbcedd7a56e4bfd217805687a24a3f5029ccc"
    ]
    static let helperSources = ["ArchiveSDK.h", "ArchiveSDK.cpp", "main.mm"]
    static let sourceFiles = ["Sources/LICENSE.txt", "Sources/scripts/build-sevenzip-worker.py", "Sources/scripts/sevenzip_reference.py"] + helperSources.map { "Sources/Tools/SevenZipWorker/" + $0 }
    static let resources = ["License.txt", "copying.txt", "unRarLicense.txt", "readme.txt", "7z2606-src.tar.xz", "BUILD.md"] + sourceFiles
    static let files = [workerPath, libraryPath] + resources.map { resource + "/" + $0 }

    struct Identity: Sendable, Equatable {
        let identifier: String, team: String?, adhoc: Bool, codeDirectoryHash: Data, manifestHash: String
    }
    struct Locations { let worker: URL, library: URL, identity: Identity }
    struct Manifest: Decodable {
        struct Build: Decodable {
            struct Inputs: Decodable {
                let architecture: String, SDKVersion: String, SDKSourceSHA256: String, minimumOS: String
                let helperSourcesSHA256: [String: String], buildRecipeSHA256: String
                let SDKChanges: [String: String]
            }
            let inputs: Inputs
        }
        let version: Int, SDKVersion: String, SDKSourceSHA256: String
        let architectures: [String], filesSHA256: [String: String], builds: [String: Build]
        func validate() throws {
            guard version == 1, SDKVersion == SevenZipBundleVerifier.sdkVersion,
                  SDKSourceSHA256 == SevenZipBundleVerifier.sourceSHA256,
                  Set(filesSHA256.keys) == Set(SevenZipBundleVerifier.files),
                  filesSHA256.values.allSatisfy(SevenZipBundleVerifier.validHash),
                  architectures == architectures.sorted(), !architectures.isEmpty,
                  Set(architectures).count == architectures.count, Set(architectures).isSubset(of: ["arm64", "x86_64"]),
                  Set(builds.keys) == Set(architectures) else { throw SevenZipBundleError.invalidManifest }
            for (architecture, build) in builds {
                let inputs = build.inputs
                guard inputs.architecture == architecture, inputs.SDKVersion == SDKVersion, inputs.SDKSourceSHA256 == SDKSourceSHA256,
                      inputs.minimumOS == "14.0", inputs.SDKChanges == SevenZipBundleVerifier.sdkChanges, Set(inputs.helperSourcesSHA256.keys) == Set(SevenZipBundleVerifier.helperSources),
                      inputs.helperSourcesSHA256.values.allSatisfy(SevenZipBundleVerifier.validHash),
                      SevenZipBundleVerifier.validHash(inputs.buildRecipeSHA256) else { throw SevenZipBundleError.invalidManifest }
            }
        }
    }
    static func validHash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    static func verify(_ supplied: URL, check: () throws -> Void) throws -> Locations {
        try check()
        guard supplied.isFileURL, !supplied.path.utf8.contains(0) else { throw SevenZipBundleError.unavailable }
        let app = supplied.standardizedFileURL, tree = try ReadOnlyBundle(app: app)
        // Reject links and FIFOs before asking Security to traverse the bundle by path.
        let metadata = try tree.read("Contents/Info.plist", maximum: 1_048_576, check: check)
        guard let info = try? PropertyListSerialization.propertyList(from: metadata, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier == "org.taro6222.files-for-mac" || identifier.hasPrefix("org.taro6222.files-for-mac.qa."),
              info["CFBundleExecutable"] as? String == "FilesMac", info["FilesArchiveSDKVersion"] as? String == sdkVersion,
              let channel = info["FilesReleaseChannel"] as? String, ["preview", "stable"].contains(channel) else { throw SevenZipBundleError.invalidManifest }
        let manifestData = try tree.read(resource + "/manifest.json", maximum: 1_048_576, check: check)
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else { throw SevenZipBundleError.invalidManifest }
        try manifest.validate()
        #if arch(arm64)
        let native = "arm64"
        #elseif arch(x86_64)
        let native = "x86_64"
        #else
        throw SevenZipBundleError.incompatibleArchitecture
        #endif
        guard manifest.architectures.contains(native) else { throw SevenZipBundleError.incompatibleArchitecture }
        try tree.verifyLayout()
        try tree.recordRegular("Contents/MacOS/FilesMac")
        for name in files { try tree.recordRegular(name) }
        let appSignature = try signature(app)
        guard appSignature.identifier == identifier else { throw SevenZipBundleError.invalidSignature }
        if app.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path { try checkRunningHost(against: app) }
        let adhoc = appSignature.adhoc
        if adhoc {
            guard channel == "preview", appSignature.team == nil else { throw SevenZipBundleError.invalidSignature }
        } else {
            try requireDeveloperID(app, team: appSignature.team)
        }
        for (path, expectedID) in [(workerPath, "org.taro6222.files-for-mac.sevenzip-worker"), (libraryPath, "org.taro6222.files-for-mac.sevenzip")] {
            try check()
            let url = app.appendingPathComponent(path), signed = try signature(url)
            guard signed.identifier == expectedID, signed.adhoc == adhoc, signed.team == appSignature.team else { throw SevenZipBundleError.invalidSignature }
            if path == workerPath {
                try validateWorkerPolicy(entitlements: signed.entitlements, info: signed.info)
            }
            if !adhoc { try requireDeveloperID(url, team: appSignature.team) }
        }
        var digests: [String: String] = [:]
        for name in files {
            let hash = try tree.hash(name, check: check)
            guard hash == manifest.filesSHA256[name] else { throw SevenZipBundleError.changedBundle }
            digests[name] = hash
        }
        guard digests[resource + "/7z2606-src.tar.xz"] == sourceSHA256 else { throw SevenZipBundleError.changedBundle }
        for build in manifest.builds.values {
            for name in helperSources {
                guard digests[resource + "/Sources/Tools/SevenZipWorker/" + name] == build.inputs.helperSourcesSHA256[name] else { throw SevenZipBundleError.changedBundle }
            }
            guard digests[resource + "/Sources/scripts/build-sevenzip-worker.py"] == build.inputs.buildRecipeSHA256 else { throw SevenZipBundleError.changedBundle }
        }
        try check()
        try tree.checkUnchanged()
        let manifestHash = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        let identity = Identity(identifier: appSignature.identifier, team: appSignature.team, adhoc: adhoc,
                                codeDirectoryHash: appSignature.codeDirectoryHash, manifestHash: manifestHash)
        return Locations(worker: app.appendingPathComponent(workerPath), library: app.appendingPathComponent(libraryPath), identity: identity)
    }

    static func validateWorkerPolicy(entitlements: [String: Any], info: [String: Any]) throws {
        guard Set(entitlements.keys) == ["com.apple.security.app-sandbox"],
              let sandbox = entitlements["com.apple.security.app-sandbox"] as? NSNumber,
              CFGetTypeID(sandbox) == CFBooleanGetTypeID(), sandbox.boolValue,
              info["CFBundleIdentifier"] as? String == "org.taro6222.files-for-mac.sevenzip-worker",
              info["CFBundleExecutable"] as? String == "SevenZipWorker",
              let background = info["LSBackgroundOnly"] as? NSNumber,
              CFGetTypeID(background) == CFBooleanGetTypeID(), background.boolValue else {
            throw SevenZipBundleError.invalidSignature
        }
    }
    private struct Signature {
        let identifier: String, team: String?, adhoc: Bool, codeDirectoryHash: Data
        let entitlements: [String: Any], info: [String: Any]
    }
    private static func staticCode(_ url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        #if arch(arm64)
        let architecture = CPU_TYPE_ARM64
        #else
        let architecture = CPU_TYPE_X86_64
        #endif
        let attributes = [kSecCodeAttributeArchitecture as String: NSNumber(value: architecture)] as CFDictionary
        guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &code) == errSecSuccess, let code else { throw SevenZipBundleError.invalidSignature }
        return code
    }
    static func checkRunningHost(against selected: URL) throws {
        var requirement: SecRequirement?, running: SecCode?
        guard SecCodeCopyDesignatedRequirement(try staticCode(selected), [], &requirement) == errSecSuccess,
              let requirement, SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], requirement) == errSecSuccess else { throw SevenZipBundleError.invalidSignature }
    }
    private static func signature(_ url: URL) throws -> Signature {
        let code = try staticCode(url)
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw SevenZipBundleError.invalidSignature }
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let dictionary = dictionary as? [String: Any], let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
              let signingFlags = dictionary[kSecCodeInfoFlags as String] as? NSNumber,
              let cdHash = dictionary[kSecCodeInfoUnique as String] as? Data, !cdHash.isEmpty, cdHash.count <= 64 else { throw SevenZipBundleError.invalidSignature }
        return Signature(identifier: identifier, team: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
                         adhoc: signingFlags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0, codeDirectoryHash: cdHash,
                         entitlements: dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:],
                         info: dictionary[kSecCodeInfoPList as String] as? [String: Any] ?? [:])
    }
    private static func requireDeveloperID(_ url: URL, team: String?) throws {
        let requirement = try developerIDRequirement(team: team)
        guard SecStaticCodeCheckValidity(try staticCode(url), SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else { throw SevenZipBundleError.invalidSignature }
    }
    static func developerIDRequirement(team: String?) throws -> SecRequirement {
        guard let team, team.utf8.count == 10, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { throw SevenZipBundleError.invalidSignature }
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { throw SevenZipBundleError.invalidSignature }
        return requirement
    }
}

/// Descriptor-relative reads never follow resource/code symlinks. The root and every read file
/// are checked again after signature/hash validation so ordinary mid-validation updates fail.
private final class ReadOnlyBundle {
    let app: URL, root: Int32
    private var snapshots: [String: stat] = [:]
    private let rootIdentity: stat
    init(app: URL) throws {
        self.app = app
        root = Darwin.open(app.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw SevenZipBundleError.unavailable }
        var info = stat()
        guard fstat(root, &info) == 0 else { Darwin.close(root); throw SevenZipBundleError.unavailable }
        rootIdentity = info
    }
    deinit { Darwin.close(root) }
    private func directory(_ path: String) throws -> Int32 {
        var fd = dup(root)
        guard fd >= 0 else { throw SevenZipBundleError.invalidLayout }
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw SevenZipBundleError.invalidLayout }
            fd = next
        }
        return fd
    }
    func regular(_ path: String) throws -> stat {
        let parts = path.split(separator: "/"), parent = try directory(parts.dropLast().joined(separator: "/"))
        defer { Darwin.close(parent) }
        guard let name = parts.last else { throw SevenZipBundleError.invalidLayout }
        var info = stat()
        guard fstatat(parent, String(name), &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw SevenZipBundleError.invalidLayout }
        return info
    }
    func recordRegular(_ path: String) throws { snapshots[path] = try regular(path) }
    private func openFile(_ path: String) throws -> (Int32, stat) {
        let parts = path.split(separator: "/"), parent = try directory(parts.dropLast().joined(separator: "/"))
        defer { Darwin.close(parent) }
        guard let name = parts.last else { throw SevenZipBundleError.invalidLayout }
        let fd = openat(parent, String(name), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SevenZipBundleError.invalidLayout }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { Darwin.close(fd); throw SevenZipBundleError.invalidLayout }
        return (fd, info)
    }
    private func readChunks(_ path: String, maximum: Int64, check: () throws -> Void, consume: (Data) -> Void) throws {
        let (fd, before) = try openFile(path); defer { Darwin.close(fd) }
        if let expected = snapshots[path], !same(expected, before) { throw SevenZipBundleError.changedBundle }
        guard before.st_size <= maximum else { throw SevenZipBundleError.invalidManifest }
        var buffer = [UInt8](repeating: 0, count: 65_536), total: Int64 = 0
        while true {
            try check()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SevenZipBundleError.invalidLayout }
            if count == 0 { break }
            total += Int64(count)
            guard total <= before.st_size, total <= maximum else { throw SevenZipBundleError.changedBundle }
            consume(Data(buffer.prefix(count)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, same(before, after), total == before.st_size else { throw SevenZipBundleError.changedBundle }
        snapshots[path] = after
    }
    func read(_ path: String, maximum: Int64, check: () throws -> Void) throws -> Data {
        var data = Data(); try readChunks(path, maximum: maximum, check: check) { data.append($0) }; return data
    }
    func hash(_ path: String, check: () throws -> Void) throws -> String {
        var hash = SHA256(); try readChunks(path, maximum: 64 * 1024 * 1024, check: check) { hash.update(data: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func verifyLayout() throws {
        var expected: [String: Set<String>] = ["Contents/Helpers": ["SevenZipWorker", "7z.so"], "Contents/Frameworks": [], "Contents/Resources/ThirdParty": ["7zip"]]
        for leaf in SevenZipBundleVerifier.resources + ["manifest.json"] {
            let parts = (SevenZipBundleVerifier.resource + "/" + leaf).split(separator: "/").map(String.init)
            for index in 4..<parts.count { expected[parts.prefix(index).joined(separator: "/"), default: []].insert(parts[index]) }
        }
        for (path, children) in expected {
            let fd = try directory(path)
            guard let stream = fdopendir(fd) else { Darwin.close(fd); throw SevenZipBundleError.invalidLayout }
            defer { closedir(stream) }
            var names = Set<String>()
            while true {
                errno = 0
                guard let entry = readdir(stream) else { guard errno == 0 else { throw SevenZipBundleError.invalidLayout }; break }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
                if name != "." && name != ".." { names.insert(name) }
            }
            guard names == children else { throw SevenZipBundleError.invalidLayout }
        }
    }
    private func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    func checkUnchanged() throws {
        var current = stat()
        guard lstat(app.path, &current) == 0, same(current, rootIdentity) else { throw SevenZipBundleError.changedBundle }
        for (path, before) in snapshots { guard same(before, try regular(path)) else { throw SevenZipBundleError.changedBundle } }
    }
}
