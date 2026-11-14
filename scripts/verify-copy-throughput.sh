#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <baseline ref> <candidate ref>" >&2
  exit 64
fi
baseline=$(git rev-parse --verify "$1^{commit}")
candidate=$(git rev-parse --verify "$2^{commit}")
mkdir -p build
run_dir=$(mktemp -d "$PWD/build/copy-throughput.XXXXXX")
echo "$run_dir"
fixture="$run_dir/payload.bin"
trap 'rm -f -- "$fixture"; rm -rf -- "$run_dir/source"' EXIT
dd if=/dev/urandom of="$fixture" bs=1048576 count=512
chmod 640 "$fixture"
sw_vers > "$run_dir/macos.txt"
uname -m > "$run_dir/architecture"
shasum -a 256 < "$fixture" | awk '{print $1}' > "$run_dir/fixture-sha256"

for role in baseline candidate; do
  if [[ "$role" == baseline ]]; then revision=$baseline; else revision=$candidate; fi
  printf '%s\n' "$revision" > "$run_dir/$role-sha"
  snapshot="$run_dir/source"
  mkdir "$snapshot"
  git archive "$revision" Package.swift Sources/FilesCore Sources/CLibArchive Tests | tar -x -C "$snapshot"
  mkdir "$snapshot/Sources/FilesMac"
  cat > "$snapshot/Sources/FilesMac/CopyBenchmark.swift" <<'SWIFT'
import Foundation
import FilesCore
import CryptoKit
import Darwin

@main struct CopyBenchmark {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = URL(fileURLWithPath: CommandLine.arguments[2])
        let compareNative = CommandLine.arguments[3] == "candidate"
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        let output = dest.appendingPathComponent(source.lastPathComponent)
        let journal = root.appendingPathComponent("journal", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let clock = ContinuousClock()
        func measure(native: Bool) async throws -> Double {
            let begin = clock.now
            if native {
                try nativeCopy(source: source, output: output, journal: journal)
            } else {
                let report = await CopyEngine.run(sources: [source], destination: dest, journalDirectory: journal,
                                                  cancellation: CopyCancellation())
                guard report.state == "completed", report.journalError == nil else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let duration = begin.duration(to: clock.now).components
            guard let undo = CopyEngine.latestUndoCopy(journalDirectory: journal),
                  undo.items.count == 1, undo.items.first?.target == output,
                  (try fm.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int) == 0o640 else {
                fatalError("Copy, permissions, or undo record failed")
            }
            guard await CopyEngine.undoCopy(undo, journalDirectory: journal).state == "completed" else {
                fatalError("Undo rejected copied output")
            }
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        var copies: [Double] = [], nativeCopies: [Double] = []
        for index in 0..<5 {
            if compareNative && index.isMultiple(of: 2) { nativeCopies.append(try await measure(native: true)) }
            copies.append(try await measure(native: false))
            if compareNative && !index.isMultiple(of: 2) { nativeCopies.append(try await measure(native: true)) }
        }
        print(String(decoding: try JSONEncoder().encode(["files": copies, "native": nativeCopies]), as: UTF8.self))
    }

    // Single-file reference for the same content checks, exclusive publication and
    // persisted undo snapshot. The benchmark owns both paths and uses no cancellation.
    private static func nativeCopy(source: URL, output: URL, journal: URL) throws {
        func sample(_ url: URL) throws -> (identity: String, mode: Int, digest: String) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw CocoaError(.fileReadUnknown)
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
            return ("\(info.st_dev):\(info.st_ino):\(info.st_mode & S_IFMT)", Int(info.st_mode & 0o7777),
                    hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        let fm = FileManager.default
        let id = UUID()
        let stage = output.deletingLastPathComponent().appendingPathComponent(".native-\(id.uuidString)")
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        let record = journal.appendingPathComponent("\(id.uuidString).json")
        var report = CopyReportFixture(source: source, target: output, state: "running")
        try JSONEncoder().encode(report).write(to: record, options: .atomic)
        let before = try sample(source)
        try fm.copyItem(at: source, to: stage)
        defer { try? fm.removeItem(at: stage) }
        let copy = try sample(stage)
        let after = try sample(source)
        guard before == after, copy.digest == before.digest, copy.mode == before.mode else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard renamex_np(stage.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        report.state = "completed"
        try JSONEncoder().encode(report).write(to: record, options: .atomic)
        let undo: [String: Any] = [
            "operationId": id.uuidString, "createdAt": Date().timeIntervalSinceReferenceDate,
            "items": [["target": output.absoluteString, "targetIdentity": copy.identity,
                       "targetSnapshot": ["": "file:\(copy.mode):\(copy.digest)"]]],
        ]
        try JSONSerialization.data(withJSONObject: undo).write(
            to: journal.appendingPathComponent("undo-copy-\(id.uuidString).json"), options: .atomic)
    }

    private struct CopyReportFixture: Encodable {
        let source: URL
        let target: URL
        var state: String
    }
}
SWIFT
  (
    cd "$snapshot"
    swift build -c release --disable-sandbox >&2
    bin=$(swift build -c release --show-bin-path)
    "$bin/FilesMac" "$run_dir/$role" "$fixture" "$role"
  ) > "$run_dir/$role-seconds.json"
  rm -rf -- "$snapshot"
done
