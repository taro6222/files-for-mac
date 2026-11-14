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

@main struct CopyBenchmark {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = URL(fileURLWithPath: CommandLine.arguments[2])
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        let output = dest.appendingPathComponent(source.lastPathComponent)
        let journal = root.appendingPathComponent("journal", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<5 {
            let begin = clock.now
            let report = await CopyEngine.run(sources: [source], destination: dest, journalDirectory: journal,
                                              cancellation: CopyCancellation())
            let duration = begin.duration(to: clock.now).components
            guard report.state == "completed", report.journalError == nil,
                  let undo = CopyEngine.latestUndoCopy(journalDirectory: journal),
                  undo.items.count == 1, undo.items.first?.target == output,
                  (try fm.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int) == 0o640 else {
                fatalError("Copy, permissions, or undo record failed")
            }
            samples.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            guard await CopyEngine.undoCopy(undo, journalDirectory: journal).state == "completed" else {
                fatalError("Undo rejected copied output")
            }
        }
        print(String(decoding: try JSONEncoder().encode(samples), as: UTF8.self))
    }
}
SWIFT
  (
    cd "$snapshot"
    swift build -c release --disable-sandbox >&2
    bin=$(swift build -c release --show-bin-path)
    "$bin/FilesMac" "$run_dir/$role" "$fixture"
  ) > "$run_dir/$role-seconds.json"
  rm -rf -- "$snapshot"
done
