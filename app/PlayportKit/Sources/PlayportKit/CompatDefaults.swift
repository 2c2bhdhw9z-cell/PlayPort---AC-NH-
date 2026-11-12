// SPDX-License-Identifier: GPL-3.0-or-later
// Per-title compatibility defaults (decision 0074): launch settings known to make a game
// work, its default for everyone. The app ships them as Titles/compat-defaults.json:
//
//   {"titles": {"epic-Buffalo": {"settings": {"aspect": "16:9"},
//                                "reason": "This game draws nothing on a screen wider than 16:9."},
//               "app-15100": {"controls": "keyboardMouse", "reason": "..."},
//               "app-244210": {"executable": "acs.exe", "reason": "..."}}}
//
// keyed by catalogue id (case-sensitive: Epic app names have capitals), each entry a
// LaunchSettings object in the --settings JSON form, the game's starting on-screen layout
// (`controls`, an OnScreenLayout; ControlsState.resolve), the executable Play starts in place
// of the store's launch entry (`executable`, a path under the game's folder; Adoption.scan), or
// any of them together, and a short player-facing reason. The
// file reaches players: it names no issue, run or build; where an entry comes from is in
// the decision and evidence records. Precedence for one launch setting: the person's own
// choice on the game's page, then the title's compatibility default, then Settings, then
// Playport's built-in default; a game page's reset goes back to the compatibility default.
// Runtime keys and Graphics options take that precedence per key (decision 0091).

import Foundation
import SteamClientKit   // WindowsName (ContentKit)

public struct CompatDefaults: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// Empty when the entry sets only `controls`.
        public let settings: LaunchSettings
        /// The game's starting on-screen layout, under the person's own for the game.
        public let controls: OnScreenLayout?
        /// Shown on the game's page, after "Set for this game's compatibility".
        public let reason: String
        /// The executable Play starts, relative to the game's folder (`\` or `/` between folders),
        /// in place of the store's launch entry: a Steam receipt's, which then passes no arguments
        /// (Adoption.scan). Nil: the store's.
        public var executable: String? = nil
    }

    public let entries: [String: Entry]

    public static let fileName = "compat-defaults.json"
    public static let empty = CompatDefaults(entries: [:])

    public init(entries: [String: Entry]) { self.entries = entries }

    public func entry(for id: String) -> Entry? { entries[id] }

    /// Each entry's `executable`, by catalogue id: what Adoption.scan starts in place of a receipt's.
    public var executables: [String: String] { entries.compactMapValues(\.executable) }

    /// Reads `<directory>/compat-defaults.json`.
    public static func load(directory: URL) throws -> CompatDefaults {
        try parse(Data(contentsOf: directory.appendingPathComponent(fileName)))
    }

    /// The table, checked: only `titles`; ids as the catalogue writes them; only `settings`,
    /// `controls`, `executable` and `reason` in an entry, with `settings`, `controls` or
    /// `executable`; `controls` a layout's name; `executable` a relative path to a `.exe`
    /// (validExecutable); each setting a LaunchSettings key whose value reads back as
    /// written and a launch takes; a reason with no project-internal reference.
    public static func parse(_ data: Data) throws -> CompatDefaults {
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CompatDefaultsError.notAnObject("the file")
        }
        if let k = top.keys.first(where: { $0 != "titles" }) { throw CompatDefaultsError.unknownKey(k) }
        guard let titles = top["titles"] as? [String: Any] else { throw CompatDefaultsError.notAnObject("titles") }
        var entries: [String: Entry] = [:]
        for (id, value) in titles {
            guard id.range(of: #"^[a-z]+-[A-Za-z0-9 ._-]+$"#, options: .regularExpression) != nil else {
                throw CompatDefaultsError.badTitle(id)
            }
            guard let entry = value as? [String: Any] else { throw CompatDefaultsError.notAnObject(id) }
            if let k = entry.keys.first(where: { !["settings", "controls", "executable", "reason"].contains($0) }) {
                throw CompatDefaultsError.unknownKey("\(id).\(k)")
            }
            guard let reason = (entry["reason"] as? String)?.trimmingCharacters(in: .whitespaces), !reason.isEmpty else {
                throw CompatDefaultsError.noReason(id)
            }
            if containsInternalReference(reason) { throw CompatDefaultsError.internalReference(id) }
            var controls: OnScreenLayout?
            if let value = entry["controls"] {
                guard let name = value as? String, let layout = OnScreenLayout(rawValue: name) else {
                    throw CompatDefaultsError.badSetting("\(id).controls")
                }
                controls = layout
            }
            var executable: String?
            if let value = entry["executable"] {
                guard let path = value as? String, validExecutable(path) else { throw CompatDefaultsError.badSetting("\(id).executable") }
                executable = path
            }
            let raw = entry["settings"] as? [String: Any]
            guard raw.map({ !$0.isEmpty }) ?? ((controls != nil || executable != nil) && entry["settings"] == nil) else {
                throw CompatDefaultsError.notAnObject("\(id).settings")
            }
            entries[id] = Entry(settings: try raw.map { try settings($0, id: id) } ?? LaunchSettings(), controls: controls, reason: reason,
                                executable: executable)
        }
        return CompatDefaults(entries: entries)
    }

    /// A path under a game's folder to a Windows executable: folders and the file joined by `\`
    /// or `/`, none empty, `.`, `..` or a drive (`C:`), each a name Windows can hold, the last
    /// ending in `.exe`.
    public static func validExecutable(_ path: String) -> Bool {
        let parts = path.split(separator: "\\", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: "/", omittingEmptySubsequences: false) }.map(String.init)
        guard let last = parts.last, last.lowercased().hasSuffix(".exe"), last.count > 4 else { return false }
        return parts.allSatisfy { (try? WindowsName.check($0)) != nil }
    }

    /// An issue id (`PLA-108`) or the tracker's address: what a shipped string must not hold.
    public static func containsInternalReference(_ text: String) -> Bool {
        text.range(of: #"(?i)\bPLA-[0-9]+|linear\.app"#, options: .regularExpression) != nil
    }

    private static func settings(_ raw: [String: Any], id: String) throws -> LaunchSettings {
        let data = try JSONSerialization.data(withJSONObject: raw)
        let s = try JSONDecoder().decode(LaunchSettings.self, from: data)
        // LaunchSettings skips what it does not know: a key it dropped or read otherwise is refused.
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any] ?? [:]
        for (k, v) in raw {
            guard let b = back[k], try same(b, v) else { throw CompatDefaultsError.badSetting("\(id).\(k)") }
        }
        if let screen = s.screen, !LaunchPlan.validScreen(screen) { throw CompatDefaultsError.badSetting("\(id).screen") }
        if let aspect = s.aspect, ScreenAspect(rawValue: aspect) == nil { throw CompatDefaultsError.badSetting("\(id).aspect") }
        if let limit = s.frameLimit, limit < 0 { throw CompatDefaultsError.badSetting("\(id).frameLimit") }
        if let pool = s.jitPoolMB, !(JitPool.minimumMB...JitPool.maximumMB).contains(pool) || pool % 16 != 0 {
            throw CompatDefaultsError.badSetting("\(id).jitPoolMB")
        }
        return s
    }
}

/// Two JSON values alike, as their canonical text.
private func same(_ a: Any, _ b: Any) throws -> Bool {
    let o: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
    return try JSONSerialization.data(withJSONObject: a, options: o) == JSONSerialization.data(withJSONObject: b, options: o)
}

public enum CompatDefaultsError: Error, Equatable {
    case notAnObject(String)
    case unknownKey(String)
    case badTitle(String)
    case noReason(String)
    case badSetting(String)
    case internalReference(String)
}

extension LaunchSettings {
    /// These settings (a person's own for a game) over `base` (the game's compatibility
    /// default): each setting this level has wins, the rest come from `base`. Runtime keys
    /// and Graphics options merge by key (keyItems, decision 0091); Arguments, free text with
    /// no keys, are the person's alone once typed.
    /// endLauncherAfterSignIn is the compatibility default's alone (decisions 0124, 0125, 0130): a
    /// person's value is dropped, with or without a default.
    public func over(_ base: LaunchSettings?) -> LaunchSettings {
        guard let base else {
            var own = self
            own.endLauncherAfterSignIn = nil
            return own
        }
        func text(_ own: String, _ b: String) -> String { own.trimmingCharacters(in: .whitespaces).isEmpty ? b : own }
        return LaunchSettings(screen: screen ?? base.screen, aspect: aspect ?? base.aspect, frameLimit: frameLimit ?? base.frameLimit,
                              graphics: graphics ?? base.graphics, arguments: text(arguments, base.arguments),
                              steamAPI: steamAPI ?? base.steamAPI, cloudSync: cloudSync ?? base.cloudSync,
                              ordering: ordering.isEmpty ? base.ordering : ordering, maxInst: maxInst ?? base.maxInst,
                              x87Reduced: x87Reduced ?? base.x87Reduced, diskCache: diskCache ?? base.diskCache,
                              runtime: Self.keyItems(runtime, over: base.runtime),
                              graphicsOptions: Self.keyItems(graphicsOptions, over: base.graphicsOptions),
                              windowsServices: windowsServices ?? base.windowsServices,
                              jitPoolMB: jitPoolMB ?? base.jitPoolMB,
                              khronosVulkanLoader: khronosVulkanLoader ?? base.khronosVulkanLoader,
                              endLauncherAfterSignIn: base.endLauncherAfterSignIn)
    }

    /// `key=value` items as typed (Runtime keys, Graphics options) over the default's: the
    /// default's items whose key the person's text does not name, then the person's text as
    /// typed. A person's key wins (`MADEIRA_KEEP_SMC=0` turns that default off); every other
    /// key of the default stays. An item with no `=` is its own key.
    public static func keyItems(_ own: String, over base: String) -> String {
        let ownText = own.trimmingCharacters(in: .whitespaces)
        guard !ownText.isEmpty else { return base }
        func key(_ item: String) -> String { item.firstIndex(of: "=").map { String(item[..<$0]) } ?? item }
        let named = Set(splitArguments(ownText).map(key))
        let kept = splitArguments(base).filter { !named.contains(key($0)) }.map { $0.contains(" ") ? "\"\($0)\"" : $0 }
        return (kept + [ownText]).joined(separator: " ")
    }
}
