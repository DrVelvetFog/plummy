import Foundation

// MeetingNotes containment harness: hostile session ids must never place a notes folder
// outside ~/Documents/Plummy Notes/. Build and run (from the repo root):
//
//     swiftc -o /tmp/plummy-containment Mac/Sources/PlummyMac/MeetingNotes.swift \
//         tools/security-harness/main.swift && /tmp/plummy-containment
//
// NOTE: this runs against the real notes root; every folder it creates is empty and is
// removed again before exit. Exit 0 = all contained.
let cases = ["../../..", "x/../../e", "a1b2c3d4", "..", "////////", "", ". . . .", "..9chars!", "alphaone", "alphatwo"]
var failures = 0
var created: [URL] = []
let fm = FileManager.default
let rootPath = MeetingNotes.root.standardizedFileURL.path
print("root: \(rootPath)")
for (i, id) in cases.enumerated() {
    let url = MeetingNotes.folder(session: id, started: Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 90_000))
    created.append(url)
    let resolved = url.standardizedFileURL.path
    let contained = resolved.hasPrefix(rootPath + "/")
    let safeName = !url.lastPathComponent.contains("..") && !url.lastPathComponent.contains("/")
    print("\(contained && safeName ? "OK  " : "FAIL") id=\(String(reflecting: id)) -> \(resolved)")
    if !(contained && safeName) { failures += 1 }
}
// Distinct ids must not collide through the suffix lookup.
if created[8] == created[9] { print("FAIL distinct ids collided"); failures += 1 }
else { print("OK   distinct ids distinct folders") }
// Clean up: remove every folder this run created that holds no files.
for url in Set(created) where url.standardizedFileURL.path.hasPrefix(rootPath + "/") {
    let files = (try? fm.subpathsOfDirectory(atPath: url.path))?.filter {
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.appendingPathComponent($0).path, isDirectory: &isDir)
        return !isDir.boolValue
    } ?? []
    if files.isEmpty { try? fm.removeItem(at: url) }
}
print(failures == 0 ? "ALL CONTAINED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
