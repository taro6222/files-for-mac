import Foundation
import Darwin

struct MergeDirectoryMutation: Codable, Sendable {
    let identity: String
    let modificationDate: Date

    static func canonicalPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBytes { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        guard result == 0 else { return nil }
        return String(cString: buffer)
    }
    static func capture(_ descriptor: Int32) -> (String, Self)? {
        guard let path = canonicalPath(descriptor) else { return nil }
        let url = URL(fileURLWithPath: path)
        var before = stat(), after = stat()
        guard CopyEngine.matchesPublicationHandle(url, descriptor: descriptor), fstat(descriptor, &before) == 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date,
              fstat(descriptor, &after) == 0,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              CopyEngine.matchesPublicationHandle(url, descriptor: descriptor),
              let identity = try? CopyEngine.entryIdentity(url) else { return nil }
        return (path, Self(identity: identity, modificationDate: date))
    }
}

/// Used sequentially by the batch's background preparation/finalization tasks; the lock owns contexts.
final class MergeUndoConsolidator: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [Context] = []

    func capture(items: [CopyUndoItem], touchedTargets: [URL]) {
        lock.withLock {
            for (index,item) in items.enumerated() {
                guard item.targetSnapshot[""]?.hasPrefix("directory:") == true, item.targetMetadata?.creationDates != nil,
                      item.targetMetadata?.owners?.count == item.targetSnapshot.count,
                      !contexts.contains(where: { $0.index == index }),
                      touchedTargets.contains(where: { Self.mightContain(item.target, child: $0) }),
                      let context = try? Context(index: index, item: item) else { continue }
                contexts.append(context)
            }
        }
    }
    func finish(items: [CopyUndoItem], mutations: [String: MergeDirectoryMutation]) -> [CopyUndoItem] {
        lock.withLock {
            var result = items
            var absorbed = Set<Int>()
            for context in contexts.sorted(by: { $0.item.target.pathComponents.count < $1.item.target.pathComponents.count }) {
                guard !absorbed.contains(context.index), context.matches() else { continue }
                var expected = context.item.targetSnapshot
                guard var metadata = context.item.targetMetadata else { continue }
                var descendants: [Int] = []
                var identities = context.item.descendantIdentities ?? [:]
                var invalid = false
                for index in items.indices where index > context.index {
                    let item = items[index]
                    guard let prefix = context.relative(item.target), !prefix.isEmpty else { continue }
                    guard let childMetadata = item.targetMetadata, childMetadata.creationDates != nil,
                          childMetadata.owners?.count == item.targetSnapshot.count else { invalid = true; break }
                    let rawIdentity: String
                    if let childContext = contexts.first(where: { $0.index == index }), childContext.matches(),
                       let currentIdentity = try? CopyEngine.checkedPublicationIdentity(at: item.target,
                            descriptor: childContext.descriptor, identity: CopyEngine.entryIdentity) {
                        rawIdentity = currentIdentity
                    } else {
                        rawIdentity = item.targetIdentity.hasPrefix(CopyEngine.consolidatedUndoPrefix)
                            ? String(item.targetIdentity.dropFirst(CopyEngine.consolidatedUndoPrefix.count)) : item.targetIdentity
                    }
                    guard (try? CopyEngine.matchesRecordedIdentity(at: item.target, expected: rawIdentity, identity: CopyEngine.entryIdentity)) == true else {
                        invalid = true; break
                    }
                    identities[prefix] = rawIdentity
                    for (key,value) in item.descendantIdentities ?? [:] { identities[prefix + key] = value }
                    for (key,value) in item.targetSnapshot { expected[prefix + key] = value }
                    for (key,value) in childMetadata.extendedAttributes { metadata.extendedAttributes[prefix + key] = value }
                    for (key,value) in childMetadata.accessControlLists { metadata.accessControlLists[prefix + key] = value }
                    for (key,value) in childMetadata.modificationDates { metadata.modificationDates[prefix + key] = value }
                    for (key,value) in childMetadata.creationDates ?? [:] { metadata.creationDates?[prefix + key] = value }
                    for (key,value) in childMetadata.owners ?? [:] { metadata.owners?[prefix + key] = value }
                    descendants.append(index)
                }
                guard !invalid, !descendants.isEmpty else { continue }
                for (path,mutation) in mutations {
                    let parent = URL(fileURLWithPath: path)
                    guard let key = context.relative(parent, canonical: true), expected[key]?.hasPrefix("directory:") == true,
                          (try? CopyEngine.entryIdentity(parent)) == mutation.identity else { continue }
                    metadata.modificationDates[key] = mutation.modificationDate
                }
                guard let current = try? CopyEngine.makeSnapshot(context.item.target, cancellation: CopyCancellation()),
                      current.withPermissions == expected, current.metadata.matchesRecorded(metadata), context.matches(),
                      let identity = try? CopyEngine.checkedPublicationIdentity(at: context.item.target,
                        descriptor: context.descriptor, identity: CopyEngine.entryIdentity) else { continue }
                let candidate = CopyUndoItem(target: context.item.target,
                    targetIdentity: CopyEngine.consolidatedUndoPrefix + identity,
                    targetSnapshot: expected, targetMetadata: metadata, descendantIdentities: identities)
                guard (try? CopyEngine.matchesUndoTarget(candidate)) == true, context.matches() else { continue }
                result[context.index] = candidate
                absorbed.formUnion(descendants)
            }
            return result.enumerated().filter { !absorbed.contains($0.offset) }.map(\.element)
        }
    }
    private static func mightContain(_ root: URL, child: URL) -> Bool {
        let a = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let b = child.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(child.lastPathComponent).standardizedFileURL.pathComponents
        guard b.count > a.count else { return false }
        func fold(_ value: String) -> String { value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping }
        return zip(a,b).allSatisfy { fold($0.0) == fold($0.1) }
    }
    private final class Context {
        let index: Int
        let item: CopyUndoItem
        let descriptor: Int32
        init(index: Int, item: CopyUndoItem) throws {
            let fd = open(item.target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            do {
                guard try CopyEngine.matchesUndoTarget(item), CopyEngine.matchesPublicationHandle(item.target, descriptor: fd) else {
                    throw CocoaError(.fileReadUnknown)
                }
            } catch { close(fd); throw error }
            descriptor = fd; self.index = index; self.item = item
        }
        func matches() -> Bool { CopyEngine.matchesPublicationHandle(item.target, descriptor: descriptor) }
        func relative(_ url: URL, canonical: Bool = false) -> String? {
            guard matches(), let root = MergeDirectoryMutation.canonicalPath(descriptor) else { return nil }
            let actual: String
            if canonical { actual = url.path }
            else {
                let parent = url.deletingLastPathComponent()
                let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { return nil }
                defer { close(fd) }
                guard let path = MergeDirectoryMutation.canonicalPath(fd) else { return nil }
                actual = URL(fileURLWithPath: path).appendingPathComponent(url.lastPathComponent).path
            }
            if actual == root { return "" }
            guard actual.hasPrefix(root + "/") else { return nil }
            return String(actual.dropFirst(root.count))
        }
        deinit { close(descriptor) }
    }
}
