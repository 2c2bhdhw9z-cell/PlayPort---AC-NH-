// SPDX-License-Identifier: GPL-3.0-or-later
// Install mods on Assetto Corsa's page: a .zip or a folder picked in Files, unpacked into the
// game's folder (C:\Games\<its folder>), over what is there. Where each file goes:
//
// 1. a `content` folder (`content\cars\…`, `content\tracks\…`) marks the game's folder: what is
//    beside it goes there too (a content pack with Custom Shaders Patch, `extension`, `apps`);
// 2. else a `dwrite.dll` (Custom Shaders Patch) marks it, with what is beside it (its `extension`);
// 3. else `cars\<car>` and `tracks\<track>` go under `content`;
// 4. else a folder holding a car (`data.acd`, `ui\ui_car.json`, `data\car.ini`) is one under
//    `content\cars`, one holding a track (`ui\ui_track.json`, a layout's, `models*.ini`,
//    `data\surfaces.ini`) one under `content\tracks`; the zip's own name names one at its top;
// 5. else an `extension` or `apps` folder marks the game's folder.
//
// Files outside what was found (readmes, pictures) are left out, and so is a `steam_api*.dll`,
// which Playport's Steam client handles. A folder or file that is there already in another case
// is written over in its spelling: the guest sees one name.

import Foundation
import SteamClientKit   // ZipArchive, InstallFS, WindowsName (ContentKit)
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum AssettoCorsaMods {
    public struct Plan: Equatable, Sendable {
        public struct File: Equatable, Sendable {
            /// Zip: the entry's path; folder: the path under it.
            public var from: String
            /// Under the game's folder, `/`-separated.
            public var to: String
            public var size: UInt64
        }

        public var files: [File]
        /// The `content\cars` and `content\tracks` folders it writes to.
        public var cars: [String]
        public var tracks: [String]
        /// It holds Custom Shaders Patch's dwrite.dll.
        public var shadersPatch: Bool
        /// Files left out.
        public var skipped: Int
        public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }

        /// What it installs, for the player: "Custom Shaders Patch, 2 cars (a, b), 1 track (srp)".
        public var summary: String {
            func list(_ items: [String], _ one: String, _ many: String) -> String? {
                guard !items.isEmpty else { return nil }
                let names = items.prefix(3).joined(separator: ", ") + (items.count > 3 ? ", …" : "")
                return "\(items.count) \(items.count == 1 ? one : many) (\(names))"
            }
            let parts = [shadersPatch ? "Custom Shaders Patch" : nil, list(cars, "car", "cars"), list(tracks, "track", "tracks")]
                .compactMap { $0 }
            return parts.isEmpty ? "\(files.count) file\(files.count == 1 ? "" : "s")" : parts.joined(separator: ", ")
        }
    }

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case unknownLayout
        case empty
        case unreadable(String)

        public var description: String {
            switch self {
            case .unknownLayout:
                "Playport can't tell where this goes in Assetto Corsa: it holds no content folder, car, track or Custom Shaders Patch."
            case .empty: "There is nothing to install there."
            case let .unreadable(why): "Playport can't install this: \(why)"
            }
        }
    }

    /// Where each of `files` (paths `/`- or `\`-separated, with sizes) goes in the game's folder.
    /// `name` (the zip's name without `.zip`, or the folder's) names a car or track at the top.
    public static func plan(_ files: [(path: String, size: UInt64)], name: String) throws -> Plan {
        struct Item {
            var from: String
            var parts: [String]
            var lower: [String]
            var size: UInt64
        }
        let all = files.compactMap { f -> Item? in
            let parts = f.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
            let lower = parts.map { $0.lowercased() }
            guard !parts.isEmpty, lower.first != "__macosx", lower.last != ".ds_store", lower.last != "thumbs.db" else { return nil }
            return Item(from: f.path, parts: parts, lower: lower, size: f.size)
        }
        guard !all.isEmpty else { throw Refusal.empty }
        func under(_ prefix: [String], _ item: Item) -> Bool {
            item.lower.count > prefix.count && Array(item.lower.prefix(prefix.count)) == prefix.map { $0.lowercased() }
        }
        var mapped: [(from: String, to: [String], size: UInt64)] = []

        /// The shortest prefix before a component that `marker` takes (lowercased, and whether it
        /// is the file's name), with at least `after` components after it.
        func anchor(after: Int, _ marker: (String, Bool) -> Bool) -> [String]? {
            all.compactMap { f -> [String]? in
                let l = f.lower
                guard let i = l.indices.first(where: { marker(l[$0], $0 == l.count - 1) && l.count - $0 - 1 >= after }) else { return nil }
                return Array(f.parts[..<i])
            }.min { $0.count < $1.count }
        }
        /// Everything under `prefix` at the same place under the game's folder; of the files at its
        /// top, only DLLs and INI files (Custom Shaders Patch's dwrite.dll), not readmes or pictures.
        func asRoot(_ prefix: [String]) {
            for f in all where under(prefix, f) {
                let rest = Array(f.parts.dropFirst(prefix.count))
                if rest.count == 1, !(rest[0].lowercased().hasSuffix(".dll") || rest[0].lowercased().hasSuffix(".ini")) { continue }
                mapped.append((f.from, rest, f.size))
            }
        }

        if let root = anchor(after: 2, { c, _ in c == "content" }) {
            asRoot(root)
        } else if let root = anchor(after: 0, { c, isName in isName && c == "dwrite.dll" }) {
            asRoot(root)
        } else if let root = anchor(after: 2, { c, _ in c == "cars" || c == "tracks" }) {
            for f in all where under(root, f) {
                let kind = f.lower[root.count]
                guard kind == "cars" || kind == "tracks", f.parts.count - root.count >= 3 else { continue }
                mapped.append((f.from, ["content", kind] + f.parts.dropFirst(root.count + 1), f.size))
            }
        } else {
            // Folders holding a car or a track, the shallowest; the archive's top is one too.
            var found: [(prefix: [String], kind: String)] = []
            let dirs = Set(all.flatMap { f in (0..<min(f.parts.count, 4)).map { Array(f.parts[..<$0]) } })
            for d in dirs.sorted(by: { $0.count < $1.count }) {
                guard !found.contains(where: { $0.prefix.count <= d.count && Array(d.prefix($0.prefix.count)) == $0.prefix }) else { continue }
                let inside = all.filter { under(d, $0) }.map { Array($0.lower.dropFirst(d.count)) }
                func has(_ path: [String]) -> Bool { inside.contains { $0 == path } }
                let car: Bool = has(["data.acd"]) || has(["ui", "ui_car.json"]) || has(["data", "car.ini"])
                let trackUI: Bool = has(["ui", "ui_track.json"])
                    || inside.contains { p in p.count == 3 && p[0] == "ui" && p[2] == "ui_track.json" }
                let trackModels: Bool = inside.contains { p in p.count == 1 && p[0].hasPrefix("models") && p[0].hasSuffix(".ini") }
                let trackData: Bool = has(["data", "surfaces.ini"])
                    || inside.contains { p in p.count == 3 && p[1] == "data" && p[2] == "surfaces.ini" }
                if car || trackUI || trackModels || trackData { found.append((d, car ? "cars" : "tracks")) }
            }
            for (prefix, kind) in found {
                let id = prefix.last ?? name
                for f in all where under(prefix, f) {
                    mapped.append((f.from, ["content", kind, id] + f.parts.dropFirst(prefix.count), f.size))
                }
            }
            if found.isEmpty, let root = anchor(after: 1, { c, _ in c == "extension" || c == "apps" }) {
                asRoot(root)
            }
        }
        var cars = Set<String>(), tracks = Set<String>()
        var out: [Plan.File] = [], seen = Set<String>(), skipped = all.count
        var shaders = false
        for m in mapped {
            let l = m.to.map { $0.lowercased() }
            // Playport's Steam client handles the game's steam_api: a mod's is left out.
            if l.count == 1, l[0].hasPrefix("steam_api"), l[0].hasSuffix(".dll") { continue }
            for c in m.to {
                do { try WindowsName.check(c) } catch { throw Refusal.unreadable("\(m.from): \(error)") }
            }
            guard seen.insert(l.joined(separator: "/")).inserted else {
                throw Refusal.unreadable("\(m.from) differs from another file only by case")
            }
            if l.count == 1, l[0] == "dwrite.dll" { shaders = true }
            if l.count > 3, l[0] == "content", l[1] == "cars" { cars.insert(m.to[2]) }
            if l.count > 3, l[0] == "content", l[1] == "tracks" { tracks.insert(m.to[2]) }
            out.append(.init(from: m.from, to: m.to.joined(separator: "/"), size: m.size))
            skipped -= 1
        }
        guard !out.isEmpty else { throw Refusal.unknownLayout }
        let order = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
        return Plan(files: out.sorted { $0.to < $1.to }, cars: cars.sorted(by: order), tracks: tracks.sorted(by: order),
                    shadersPatch: shaders, skipped: skipped)
    }

    /// The plan for a picked zip or folder.
    public static func plan(_ source: ImportSource) throws -> Plan {
        switch source {
        case let .zip(url):
            let zip: ZipArchive
            do { zip = try ZipArchive(url: url) } catch { throw Refusal.unreadable("it is not a zip Playport can read (\(error))") }
            var files: [(path: String, size: UInt64)] = []
            for e in zip.entries where !e.isDirectory && !e.isSymlink {
                if e.encrypted { throw Refusal.unreadable("\(e.path) is encrypted") }
                if e.method != 0, e.method != 8 {
                    throw Refusal.unreadable("\(e.path) uses \(ZipArchive.methodName(e.method)) compression; "
                                             + "only stored and deflate are supported. Unzip it in Files and pick the folder.")
                }
                files.append((e.path, e.size))
            }
            return try plan(files, name: url.deletingPathExtension().lastPathComponent)
        case let .folder(root):
            var files: [(path: String, size: UInt64)] = []
            var placeholders = 0
            func walk(_ dir: URL, _ rel: String) throws {
                for n in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
                    if n.hasPrefix("."), n.hasSuffix(".icloud") { placeholders += 1; continue }
                    let url = dir.appendingPathComponent(n)
                    var st = stat()
                    guard lstat(url.path, &st) == 0 else { throw Refusal.unreadable("\(n) cannot be read") }
                    let path = rel.isEmpty ? n : "\(rel)/\(n)"
                    switch st.st_mode & S_IFMT {
                    case S_IFDIR: try walk(url, path)
                    case S_IFREG: files.append((path, UInt64(st.st_size)))
                    default: continue
                    }
                }
            }
            try walk(root, "")
            if placeholders > 0 { throw Refusal.unreadable("\(placeholders) of its files are still in iCloud. Download the folder in Files first.") }
            return try plan(files, name: root.lastPathComponent)
        }
    }

    public struct Progress: Sendable {
        public var bytesDone: UInt64
        public var bytesTotal: UInt64
    }

    /// Writes `plan` from `source` into the game's folder `root`, each file whole beside its name
    /// and then renamed over it. Needs its bytes free plus 5% and 256 MiB.
    public static func install(_ plan: Plan, from source: ImportSource, into root: URL,
                               freeSpace: (URL) throws -> UInt64 = { try InstallFS.availableCapacity($0) },
                               progress: @escaping @Sendable (Progress) -> Void = { _ in }) throws {
        let needed = plan.totalBytes + plan.totalBytes / 20 + (256 << 20)
        let free = try freeSpace(root)
        guard free >= needed else { throw ImportError.insufficientSpace(needed: needed, available: free) }
        var zip: ZipArchive?
        if case let .zip(url) = source { zip = try ZipArchive(url: url) }
        let entries = Dictionary((zip?.entries ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var listings: [String: [String]] = [:]
        var done: UInt64 = 0
        var last = Date.distantPast
        for f in plan.files {
            if Task.isCancelled { throw CancellationError() }
            let dst = try resolve(root, f.to.split(separator: "/").map(String.init), listings: &listings)
            let part = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).part")
            try? FileManager.default.removeItem(at: part)
            var copied: UInt64 = 0
            let tick: (UInt64) -> Void = { n in
                copied += n
                if Date().timeIntervalSince(last) >= 0.5 {
                    last = Date()
                    progress(Progress(bytesDone: done + copied, bytesTotal: plan.totalBytes))
                }
            }
            switch source {
            case .zip:
                guard let zip, let e = entries[f.from] else { throw Refusal.unreadable("\(f.from) is no longer in the archive") }
                try GameImporter.write(part) { sink in try zip.extract(e) { buf in try sink(buf); tick(UInt64(buf.count)) } }
            case let .folder(src):
                try GameImporter.copy(src.appendingPathComponent(f.from), part) { tick($0) }
            }
            guard InstallFS.fileSize(part) == f.size else {
                try? FileManager.default.removeItem(at: part)
                throw Refusal.unreadable("\(f.from) came out as \(InstallFS.fileSize(part) ?? 0) bytes, not \(f.size)")
            }
            guard rename(part.path, dst.path) == 0 else { throw Refusal.unreadable("\(f.to) could not be put in place (errno \(errno))") }
            done += f.size
        }
        progress(Progress(bytesDone: plan.totalBytes, bytesTotal: plan.totalBytes))
    }

    /// `parts` under `root`, each folder matched without case and made when missing, the file's
    /// name matched without case (written over in its spelling); a symlink on the way is refused.
    static func resolve(_ root: URL, _ parts: [String], listings: inout [String: [String]]) throws -> URL {
        var at = root
        for (i, part) in parts.enumerated() {
            let names: [String]
            if let cached = listings[at.path] {
                names = cached
            } else {
                names = (try? FileManager.default.contentsOfDirectory(atPath: at.path)) ?? []
                listings[at.path] = names
            }
            let name = names.first { $0 == part } ?? names.first { $0.caseInsensitiveCompare(part) == .orderedSame } ?? part
            let next = at.appendingPathComponent(name)
            var st = stat()
            let exists = lstat(next.path, &st) == 0
            if exists, (st.st_mode & S_IFMT) == S_IFLNK { throw Refusal.unreadable("\(parts.joined(separator: "/")) passes a symlink") }
            if i < parts.count - 1 {
                if !exists {
                    guard mkdir(next.path, 0o755) == 0 || errno == EEXIST else {
                        throw Refusal.unreadable("the folder \(name) could not be made (errno \(errno))")
                    }
                    listings[at.path, default: []].append(name)
                    listings[next.path] = []
                } else if (st.st_mode & S_IFMT) != S_IFDIR {
                    throw Refusal.unreadable("\(name) is a file where the mod has a folder")
                }
            } else if exists, (st.st_mode & S_IFMT) == S_IFDIR {
                throw Refusal.unreadable("\(name) is a folder where the mod has a file")
            }
            at = next
        }
        return at
    }
}
