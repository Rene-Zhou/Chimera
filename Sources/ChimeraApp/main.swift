import Foundation
import ChimeraCore

// chimera — CLI entry point.
// M1 acceptance: `chimera list <file.chm>` enumerates entries with correct
// Chinese decoding. Parsing lands in M1; this stub reports identity for now.

let args = CommandLine.arguments

if args.count >= 2 && args[1] == "info" {
    print("\(ChimeraInfo.name) (\(ChimeraInfo.codename)) — CHM reader for macOS")
} else if args.count >= 3 && args[1] == "list" {
    do {
        let container = try CHMContainer(path: args[2])
        let entries = try container.allEntries()
        print("total entries: \(entries.count)")
        for e in entries.prefix(30) {
            print("\(e.length)\t\(e.isDirectory ? "DIR " : "    ")\(e.path)")
        }
        for key in ["/$FIftiMain", "/5R不全书（全扩展）2026.9.13.hhc", "/5R不全书（全扩展）2026.9.13.hhk"] {
            let r = container.entry(at: key)
            print("resolve \(key) -> \(r.map { "\($0.length) bytes" } ?? "nil")")
        }
        for e in entries where e.path.hasSuffix(".hhc") || e.path.hasSuffix(".hhk") {
            print("HHx: \(e.path) (\(e.length))")
        }
    } catch {
        print("error: \(error)")
        exit(1)
    }
} else if args.count >= 4 && args[1] == "read" {
    do {
        let c = try CHMContainer(path: args[2])
        guard let e = c.entry(at: args[3]) else {
            print("resolve failed: \(args[3])")
            exit(1)
        }
        print("entry: \(e.path) length=\(e.length)")
        do {
            let d = try c.read(e.path)
            print("full read OK: \(d.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))")
        } catch { print("full read FAILED: \(error)") }
        for size in [65536, 32768, 8192, 2048] {
            do {
                let d = try c.read(e.path, range: 0..<UInt64(size))
                print("chunk \(size) OK: \(d.count) bytes")
            } catch { print("chunk \(size) FAILED: \(error)") }
        }
    } catch {
        print("error: \(error)")
        exit(1)
    }
} else if args.count >= 5 && args[1] == "extract" {
    do {
        let c = try CHMContainer(path: args[2])
        let data = try c.read(args[3])
        try data.write(to: URL(fileURLWithPath: args[4]))
        print("wrote \(data.count) bytes to \(args[4])")
    } catch {
        print("error: \(error)")
        exit(1)
    }
} else {
    print("usage: chimera <info | list <file.chm>>")
    exit(64)
}
