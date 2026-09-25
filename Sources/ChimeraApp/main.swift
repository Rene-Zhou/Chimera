import Foundation
import ChimeraCore

// chimera — CLI entry point.
// M1 acceptance: `chimera list <file.chm>` enumerates entries with correct
// Chinese decoding. Parsing lands in M1; this stub reports identity for now.

let args = CommandLine.arguments

if args.count >= 2 && args[1] == "about" {
    print("\(ChimeraInfo.name) (\(ChimeraInfo.codename)) — CHM reader for macOS")
} else if args.count >= 3 && args[1] == "info" {
    do {
        let c = try CHMContainer(path: args[2])
        let info = try c.systemInfo()
        let entries = try c.allEntries()
        print("title:    \(info?.title ?? "-")")
        print("lcid:     \(info?.lcid.map { String(format: "0x%04X", Int($0)) } ?? "-")")
        print("default:  \(info?.defaultTopic ?? "-")")
        print("entries:  \(entries.count)")
    } catch {
        print("error: \(error)")
        exit(1)
    }
} else if args.count >= 3 && args[1] == "toc" {
    do {
        let c = try CHMContainer(path: args[2])
        let info = try c.systemInfo()
        guard let hhc = try c.allEntries().first(where: { $0.path.hasSuffix(".hhc") })?.path else {
            print("no .hhc found")
            exit(1)
        }
        let text = CHMTextDecoder(lcid: info?.lcid).decode(try c.read(hhc))
        let toc = CHMSitemapParser.parseTOC(text)
        func dump(_ items: [CHMTocItem], _ depth: Int) {
            for it in items {
                print(String(repeating: "  ", count: depth) + it.title
                    + (it.local.map { "  → \($0)" } ?? ""))
                dump(it.children, depth + 1)
            }
        }
        dump(toc, 0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
} else if args.count >= 3 && args[1] == "list" {
    do {
        let container = try CHMContainer(path: args[2])
        let entries = try container.allEntries()
        print("total entries: \(entries.count)")
        for e in entries.prefix(30) {
            print("\(e.length)\t\(e.isDirectory ? "DIR " : "    ")\(e.path)")
        }
        for key in ["/$FIftiMain", "/DND五版不全书.hhc", "/DND五版不全书.hhk"] {
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
    print("usage: chimera <about | info <file.chm> | toc <file.chm> | list <file.chm> | read <file.chm> <entry> | extract <file.chm> <entry> <out>>")
    exit(64)
}
