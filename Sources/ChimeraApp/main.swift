import Foundation
import ChimeraCore

// chimera — CLI entry point.
// M1 acceptance: `chimera list <file.chm>` enumerates entries with correct
// Chinese decoding. Parsing lands in M1; this stub reports identity for now.

let args = CommandLine.arguments

if args.count >= 2 && args[1] == "info" {
    print("\(ChimeraInfo.name) (\(ChimeraInfo.codename)) — CHM reader for macOS")
} else if args.count >= 3 && args[1] == "list" {
    // TODO(m1-6): enumerate entries of args[2] via ChimeraCore.
    print("error: parsing not implemented yet (M1 in progress)")
    exit(2)
} else {
    print("usage: chimera <info | list <file.chm>>")
    exit(64)
}
