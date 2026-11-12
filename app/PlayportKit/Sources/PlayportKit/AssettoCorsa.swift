// SPDX-License-Identifier: GPL-3.0-or-later
// Assetto Corsa (Steam app 244210) without its launcher. Steam's launch entry is AssettoCorsa.exe,
// Kunos's .NET launcher, which does not run here, so Play starts the game itself, acs.exe (the
// title's compatibility default names it; Adoption.scan). acs.exe reads what to drive from
// `Documents\Assetto Corsa\cfg\race.ini`, which the launcher, and Content Manager, write before they
// start it. Play writes it from the choices on the game's page (Options):
//
// - no server: a practice session with the chosen car on the chosen track (the first the phone
//   has when none is chosen);
// - a server (`address:HTTP port`, or a join link): the server's HTTP port answers /INFO with its
//   track, its cars and its TCP port (`tport`); Play joins it with the chosen car when the server
//   has it, else with the first of the server's cars the phone has, as the Steam account (GUID, its
//   SteamID64). A track a server names `csp/<build>/../<track>` needs Custom Shaders Patch; the
//   game loads it as `<track>`, and so does race.ini.
//
// On a first Play (no file there yet) it also writes video.ini at the guest screen's size and
// refresh, controls.ini on an Xbox pad (Playport's controllers reach games through XInput) and
// assists.ini with a pad's helpers on. A file already there is the player's or the game's, and stays.
//
// Custom Shaders Patch is the dwrite.dll it puts in the game's folder, which the game finds there
// before the system's. AssettoCorsaMods installs it, cars and tracks into the game's folder.

import Foundation
import SteamClientKit   // InstallFS, WindowsName (ContentKit)

public enum AssettoCorsa {
    public static let appID: UInt32 = 244210
    public static let titleID = "app-\(appID)"

    /// The choices on the game's page, kept by the app; every Play writes race.ini from them.
    public struct Options: Codable, Equatable, Sendable {
        /// The server to join: `address:HTTP port` or a join link (serverAddress); empty: practice.
        public var server: String
        /// The server's password; empty for none.
        public var password: String
        /// The name other drivers see; empty: the Steam account's.
        public var driverName: String
        /// A `content\cars` folder; empty: the first the phone has (online: the first the server allows).
        public var car: String
        /// A `content\tracks` folder, `track/layout` for one of its layouts; empty: the first the phone has.
        public var track: String

        public init(server: String = "", password: String = "", driverName: String = "", car: String = "", track: String = "") {
            self.server = server
            self.password = password
            self.driverName = driverName
            self.car = car
            self.track = track
        }

        enum CodingKeys: String, CodingKey { case server, password, driverName, car, track }

        /// A key a later build added or dropped reads as empty.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
            password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
            driverName = try c.decodeIfPresent(String.self, forKey: .driverName) ?? ""
            car = try c.decodeIfPresent(String.self, forKey: .car) ?? ""
            track = try c.decodeIfPresent(String.self, forKey: .track) ?? ""
        }
    }

    // MARK: servers

    /// Where a server's HTTP port is.
    public struct ServerAddress: Equatable, Sendable {
        public var host: String
        public var httpPort: UInt16

        public init(host: String, httpPort: UInt16) {
            self.host = host
            self.httpPort = httpPort
        }

        public var text: String { "\(host):\(httpPort)" }
    }

    /// `address:HTTP port` (`157.90.1.2:8081`, `server.example.org:8081`), or a join link:
    /// Content Manager's `acmanager://race/online/join?ip=…&httpPort=…` or its web form
    /// (`https://acstuff.club/s/q:race/online/join?ip=…&httpPort=…`). Nil for anything else.
    public static func serverAddress(_ text: String) -> ServerAddress? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let q = s.firstIndex(of: "?") {
            guard let items = URLComponents(string: "http://link/" + s[q...])?.queryItems else { return nil }
            func item(_ name: String) -> String? {
                items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
            }
            guard let host = item("ip"), validHost(host), let port = item("httpPort").flatMap(UInt16.init), port > 0 else {
                return nil
            }
            return ServerAddress(host: host, httpPort: port)
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[..<colon]), port = UInt16(s[s.index(after: colon)...])
        guard validHost(host), let port, port > 0 else { return nil }
        return ServerAddress(host: host, httpPort: port)
    }

    /// A host name or IPv4 address: letters, digits, `.` and `-`, at most 253 of them.
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && !host.hasPrefix(".") && !host.hasPrefix("-")
            && host.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }
    }

    /// What a server's HTTP port says at /INFO (Kunos's server and AssettoServer alike).
    public struct ServerInfo: Equatable, Sendable {
        public var name: String
        /// As the server names it: `<track>` or `<track>-<layout>`, with `csp/<build>/../` before
        /// it when it needs Custom Shaders Patch (serverTrack).
        public var track: String
        public var cars: [String]
        /// The TCP port the game joins on (`tport`; `port`, the UDP one, when there is none).
        public var tcpPort: UInt16
        public var needsPassword: Bool
        public var clients: Int?
        public var capacity: Int?

        public init(name: String, track: String, cars: [String], tcpPort: UInt16, needsPassword: Bool = false,
                    clients: Int? = nil, capacity: Int? = nil) {
            self.name = name
            self.track = track
            self.cars = cars
            self.tcpPort = tcpPort
            self.needsPassword = needsPassword
            self.clients = clients
            self.capacity = capacity
        }
    }

    public enum ServerError: Error, Equatable, CustomStringConvertible {
        case http(Int)
        case notHTTP
        case notInfo(String)

        public var description: String {
            switch self {
            case let .http(status): "The server answered HTTP \(status), not its information."
            case .notHTTP: "The server's answer is not HTTP: is that its HTTP port?"
            case let .notInfo(why): "The server's information can't be read (\(why))."
            }
        }
    }

    /// /INFO's JSON.
    public static func serverInfo(_ data: Data) throws -> ServerInfo {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ServerError.notInfo("not a JSON object")
        }
        func int(_ k: String) -> Int? {
            if let n = o[k] as? NSNumber { return n.intValue }
            return (o[k] as? String).flatMap { Int($0) }
        }
        guard let track = o["track"] as? String, !track.isEmpty else { throw ServerError.notInfo("no track") }
        guard let port = (int("tport") ?? int("port")).flatMap({ UInt16(exactly: $0) }), port > 0 else {
            throw ServerError.notInfo("no TCP port")
        }
        let cars = (o["cars"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        return ServerInfo(name: (o["name"] as? String).map(iniValue) ?? "", track: track, cars: cars, tcpPort: port,
                          needsPassword: (o["pass"] as? Bool) ?? ((o["pass"] as? NSNumber)?.boolValue ?? false),
                          clients: int("clients"), capacity: int("maxclients"))
    }

    /// The request for a server's /INFO; the server closes the connection after its answer.
    public static func infoRequest(_ address: ServerAddress) -> Data {
        Data(("GET /INFO HTTP/1.1\r\nHost: \(address.host):\(address.httpPort)\r\nAccept: application/json\r\n"
              + "User-Agent: Playport\r\nConnection: close\r\n\r\n").utf8)
    }

    /// The body of an HTTP/1.x answer read to its end: refused unless it is 200; a chunked body is
    /// joined, a `Content-Length` one cut to that length.
    public static func httpBody(_ response: Data) throws -> Data {
        let bytes = [UInt8](response)
        guard bytes.starts(with: Array("HTTP/1.".utf8)) else { throw ServerError.notHTTP }
        guard let end = find(bytes, Array("\r\n\r\n".utf8), from: 0) else { throw ServerError.notHTTP }
        let head = String(decoding: bytes[..<end], as: UTF8.self).components(separatedBy: "\r\n")
        let status = head.first.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) } ?? 0
        guard status == 200 else { throw ServerError.http(status) }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Array(bytes[(end + 4)...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var out: [UInt8] = [], at = 0
            while let lineEnd = find(body, Array("\r\n".utf8), from: at) {
                let sizeText = String(decoding: body[at..<lineEnd], as: UTF8.self).split(separator: ";").first ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    throw ServerError.notInfo("a bad chunk")
                }
                if size == 0 { break }
                let start = lineEnd + 2
                guard start + size <= body.count else { throw ServerError.notInfo("the answer was cut short") }
                out += body[start..<(start + size)]
                at = start + size + 2
            }
            body = out
        } else if let length = headers["content-length"].flatMap({ Int($0) }), length < body.count {
            body = Array(body[..<length])
        }
        return Data(body)
    }

    private static func find(_ hay: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = from
        while i + needle.count <= hay.count {
            if hay[i] == needle[0], Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// A server's track as the game loads it, and the Custom Shaders Patch build it needs:
    /// `csp/2144/../shuto_revival_project_beta` is `shuto_revival_project_beta` and build 2144
    /// (`csp/<build>/../<flags>/../<track>` too), as Content Manager reads it.
    public static func serverTrack(_ raw: String) -> (id: String, cspBuild: Int?) {
        let csp = raw.hasPrefix("csp/")
        let pieces = String(raw.dropFirst(csp ? 4 : 0)).components(separatedBy: "/../")
        guard pieces.count == 2 || pieces.count == 3, let id = pieces.last, !id.isEmpty else { return (raw, nil) }
        return (id, Int(pieces[0]))
    }

    // MARK: what the phone has

    /// The cars and tracks in the game's `content` folder.
    public struct Content: Equatable, Sendable {
        public struct Track: Equatable, Sendable {
            public var id: String
            /// Whether the track's own `data` folder is a layout (CONFIG_TRACK empty).
            public var plain: Bool
            /// Its layouts' folders, first by name.
            public var layouts: [String]

            public init(id: String, plain: Bool, layouts: [String]) {
                self.id = id
                self.plain = plain
                self.layouts = layouts
            }

            /// What the track picker offers and Options.track holds: `id` for the plain layout,
            /// `id/layout` for each other.
            public var choices: [String] { (plain ? [id] : []) + layouts.map { "\(id)/\($0)" } }
        }

        public var cars: [String]
        public var tracks: [Track]

        public init(cars: [String], tracks: [Track]) {
            self.cars = cars
            self.tracks = tracks
        }

        /// The car folder named `id`, without case, as it is spelled on disk.
        public func car(_ id: String) -> String? {
            cars.first { $0 == id } ?? cars.first { $0.caseInsensitiveCompare(id) == .orderedSame }
        }

        public func track(_ id: String) -> Track? {
            tracks.first { $0.id == id } ?? tracks.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        }

        /// Every track choice (Track.choices), first by name.
        public var trackChoices: [String] { tracks.flatMap(\.choices) }

        /// `track` or `track/layout` (Options.track) as a track and a layout the phone has.
        public func layout(_ choice: String) -> (track: String, layout: String)? {
            let parts = choice.split(separator: "/", maxSplits: 1).map(String.init)
            guard let first = parts.first, let t = track(first) else { return nil }
            if parts.count == 1 { return t.plain ? (t.id, "") : t.layouts.first.map { (t.id, $0) } }
            let l = t.layouts.first { $0.caseInsensitiveCompare(parts[1]) == .orderedSame }
            return l.map { (t.id, $0) }
        }

        /// A server's track (serverTrack's id) split into its track and layout, as the server
        /// spells them, when the phone has that layout: the whole id when there is a track of that
        /// name (no layout), else the track before a `-` and the layout after it
        /// (`ks_nordschleife-endurance`), tried from the last `-`. Nil when the phone has none.
        public func serverLayout(_ id: String) -> (track: String, layout: String)? {
            if track(id) != nil { return (id, "") }
            var at = id.endIndex
            while let dash = id[..<at].lastIndex(of: "-") {
                let name = String(id[..<dash]), layout = String(id[id.index(after: dash)...])
                if let t = track(name), t.layouts.contains(where: { $0.caseInsensitiveCompare(layout) == .orderedSame }) {
                    return (name, layout)
                }
                at = dash
            }
            return nil
        }
    }

    /// The `content\cars` and `content\tracks` folders under the game's folder `root`. A track
    /// with a `data` folder of its own has a plain layout; each folder of it with a `data` folder
    /// is a layout.
    public static func content(root: URL) -> Content {
        let fm = FileManager.default
        func folders(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
                .filter { !$0.hasPrefix(".") && Adoption.isDirectory(url.appendingPathComponent($0)) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        let content = locateFolder("content", in: root)
        let cars = content.flatMap { locateFolder("cars", in: $0) }.map(folders) ?? []
        var tracks: [Content.Track] = []
        if let tracksDir = content.flatMap({ locateFolder("tracks", in: $0) }) {
            for id in folders(tracksDir) {
                let dir = tracksDir.appendingPathComponent(id)
                let layouts = folders(dir).filter { name in
                    !["data", "ui", "ai", "skins", "extension", "texture", "textures"].contains(name.lowercased())
                        && locateFolder("data", in: dir.appendingPathComponent(name)) != nil
                }
                let t = Content.Track(id: id, plain: locateFolder("data", in: dir) != nil, layouts: layouts)
                if t.plain || !t.layouts.isEmpty { tracks.append(t) }
            }
        }
        return Content(cars: cars, tracks: tracks)
    }

    /// The folder `name` in `dir`, without case, as the guest would find it.
    static func locateFolder(_ name: String, in dir: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let found = names.first(where: { $0 == name }) ?? names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        let url = dir.appendingPathComponent(found, isDirectory: true)
        return Adoption.isDirectory(url) ? url : nil
    }

    /// A car's skins (`content\cars\<car>\skins`), first by name.
    public static func skins(car: String, root: URL) -> [String] {
        guard let skins = locateFolder("content", in: root).flatMap({ locateFolder("cars", in: $0) })
            .flatMap({ locateFolder(car, in: $0) }).flatMap({ locateFolder("skins", in: $0) }) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: skins.path)) ?? [])
            .filter { !$0.hasPrefix(".") && Adoption.isDirectory(skins.appendingPathComponent($0)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: the session

    /// What one Play drives.
    public struct Session: Equatable, Sendable {
        public var car: String
        public var skin: String
        public var track: String
        public var layout: String
        public var driverName: String
        public var online: Online?

        public struct Online: Equatable, Sendable {
            /// The server's address as the game connects to it (an IPv4 address; the app resolves a name).
            public var ip: String
            public var tcpPort: UInt16
            public var httpPort: UInt16
            public var name: String
            public var password: String
            /// The Steam account's SteamID64, which the server checks the game's ticket against; empty when unknown.
            public var guid: String

            public init(ip: String, tcpPort: UInt16, httpPort: UInt16, name: String, password: String, guid: String) {
                self.ip = ip
                self.tcpPort = tcpPort
                self.httpPort = httpPort
                self.name = name
                self.password = password
                self.guid = guid
            }
        }

        public init(car: String, skin: String, track: String, layout: String, driverName: String, online: Online? = nil) {
            self.car = car
            self.skin = skin
            self.track = track
            self.layout = layout
            self.driverName = driverName
            self.online = online
        }

        /// For the launch screen and the log.
        public var summary: String {
            let where_ = layout.isEmpty ? track : "\(track) (\(layout))"
            if let o = online { return "\(car) on \(o.name.isEmpty ? "\(o.ip):\(o.tcpPort)" : o.name), \(where_)" }
            return "practice: \(car) on \(where_)"
        }
    }

    /// Why Play does not start; worded for the player.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case noCars
        case noTracks
        case trackMissing(String)
        case serverTrackMissing(String)
        case serverCarsMissing([String])
        case serverHasNoCars
        case serverAddress(String)

        public var description: String {
            switch self {
            case .noCars: "The game's folder has no cars (content\\cars). Check game files, or install a car with Install mods."
            case .noTracks: "The game's folder has no tracks (content\\tracks). Check game files, or install a track with Install mods."
            case let .trackMissing(t): "The track \(t) is not installed any more. Choose another in Game options."
            case let .serverTrackMissing(t):
                "The server runs on the track \(t), which this phone does not have. Install it with Install mods in Game options."
            case let .serverCarsMissing(cars):
                "The server takes only cars this phone does not have: \(cars.prefix(6).joined(separator: ", "))"
                    + (cars.count > 6 ? " and \(cars.count - 6) more" : "") + ". Install one with Install mods in Game options."
            case .serverHasNoCars: "The server lists no cars to join with."
            case let .serverAddress(text):
                "\(text) is not a server address. Enter the server's address and HTTP port (for example 157.90.1.2:8081), or its join link."
            }
        }
    }

    /// A practice session from the options: the chosen car and track when the phone has them, else the first.
    public static func practice(_ options: Options, content: Content, driverName: String,
                                skins: (String) -> [String]) -> Result<Session, Refusal> {
        guard let car = content.car(options.car) ?? content.cars.first else { return .failure(.noCars) }
        let chosen = options.track.trimmingCharacters(in: .whitespaces)
        guard let first = content.trackChoices.first else { return .failure(.noTracks) }
        guard let place = content.layout(chosen.isEmpty ? first : chosen) else { return .failure(.trackMissing(chosen)) }
        return .success(Session(car: car, skin: skins(car).first ?? "", track: place.track, layout: place.layout,
                                driverName: driverName))
    }

    /// Joining a server: its track, and the chosen car when the server has it and the phone too,
    /// else the first of the server's cars the phone has. Car and track are as the server spells them.
    public static func online(_ options: Options, info: ServerInfo, address: ServerAddress, ip: String, content: Content,
                              driverName: String, steamID: UInt64?, skins: (String) -> [String]) -> Result<Session, Refusal> {
        let trackID = serverTrack(info.track).id
        guard let place = content.serverLayout(trackID) else { return .failure(.serverTrackMissing(trackID)) }
        guard !info.cars.isEmpty else { return .failure(.serverHasNoCars) }
        let usable = info.cars.filter { content.car($0) != nil }
        let wanted = options.car.trimmingCharacters(in: .whitespaces)
        guard let car = usable.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) ?? usable.first else {
            return .failure(.serverCarsMissing(info.cars))
        }
        let online = Session.Online(ip: ip, tcpPort: info.tcpPort, httpPort: address.httpPort, name: info.name,
                                    password: iniValue(options.password), guid: steamID.map(String.init) ?? "")
        return .success(Session(car: car, skin: skins(car).first ?? "", track: place.track, layout: place.layout,
                                driverName: driverName, online: online))
    }

    /// A value on one INI line: no line breaks or control characters, and no `;`, which starts a comment.
    static func iniValue(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
            .replacingOccurrences(of: ";", with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: the files

    /// `<user profile>\Documents\Assetto Corsa\cfg`.
    public static func cfgDirectory(userProfile: URL) -> URL {
        userProfile.appendingPathComponent("Documents/Assetto Corsa/cfg", isDirectory: true)
    }

    /// `<user profile>\Documents\Assetto Corsa\logs`: the game's log.txt, and Custom Shaders Patch's.
    public static func logsDirectory(userProfile: URL) -> URL {
        userProfile.appendingPathComponent("Documents/Assetto Corsa/logs", isDirectory: true)
    }

    /// race.ini for one session, in Content Manager's layout: a practice session, or the server
    /// to join (REMOTE), the session then the server's.
    public static func raceINI(_ s: Session) -> String {
        let name = iniValue(s.driverName)
        var ini: [(String, [(String, String)])] = [
            ("HEADER", [("VERSION", "2")]),
            ("RACE", [("VERSION", "1.1"), ("MODEL", s.car), ("MODEL_CONFIG", ""), ("SKIN", s.skin), ("TRACK", s.track),
                      ("CONFIG_TRACK", s.layout), ("CARS", "1"), ("AI_LEVEL", "100"), ("FIXED_SETUP", "0"), ("PENALTIES", "1"),
                      ("JUMP_START_PENALTY", "0"), ("AUTO_START", "0"), ("OPEN_CONTROL_CONFIG", "0"), ("PIT_MODE", "0"),
                      ("CONF_MODE", ""), ("DRIFT_MODE", "0"), ("RACE_LAPS", "0")]),
            ("CAR_0", [("SETUP", ""), ("SKIN", s.skin), ("MODEL", "-"), ("MODEL_CONFIG", ""), ("BALLAST", "0"), ("RESTRICTOR", "0"),
                       ("DRIVER_NAME", name), ("NATIONALITY", ""), ("NATION_CODE", "")]),
            ("SESSION_0", s.online == nil
                ? [("NAME", "Practice"), ("TYPE", "1"), ("DURATION_MINUTES", "0"), ("SPAWN_SET", "PIT")]
                : [("NAME", "Nothing"), ("TYPE", "1"), ("DURATION_MINUTES", "0")]),
            ("GHOST_CAR", [("RECORDING", "0"), ("PLAYING", "0"), ("SECONDS_ADVANTAGE", "0"), ("LOAD", "0"), ("FILE", ""), ("ENABLED", "0")]),
            ("GROOVE", [("VIRTUAL_LAPS", "10"), ("MAX_LAPS", "30"), ("STARTING_LAPS", "0")]),
            ("DYNAMIC_TRACK", [("SESSION_START", "100"), ("RANDOMNESS", "0"), ("LAP_GAIN", "1"), ("SESSION_TRANSFER", "100")]),
            ("TEMPERATURE", [("AMBIENT", "26"), ("ROAD", "32")]),
            ("WIND", [("SPEED_KMH_MIN", "0"), ("SPEED_KMH_MAX", "0"), ("DIRECTION_DEG", "0")]),
            ("WEATHER", [("NAME", "3_clear")]),
            // Noon: Content Manager's angle for a time is 16 × (hours − 13).
            ("LIGHTING", [("SUN_ANGLE", "-16"), ("TIME_MULT", "1"), ("CLOUD_SPEED", "0.200")]),
            ("LAP_INVALIDATOR", [("ALLOWED_TYRES_OUT", "-1")]),
            ("BENCHMARK", [("ACTIVE", "0")]),
            ("REPLAY", [("ACTIVE", "0")]),
            ("RESTART", [("ACTIVE", "0")]),
            ("OPTIONS", [("USE_MPH", "0")]),
        ]
        if let o = s.online {
            ini.append(("REMOTE", [("ACTIVE", "1"), ("SERVER_IP", o.ip), ("SERVER_PORT", String(o.tcpPort)),
                                   ("SERVER_HTTP_PORT", String(o.httpPort)), ("SERVER_NAME", iniValue(o.name)),
                                   ("REQUESTED_CAR", s.car), ("NAME", name), ("TEAM", ""), ("GUID", o.guid),
                                   ("PASSWORD", o.password)]))
        } else {
            ini.append(("REMOTE", [("ACTIVE", "0"), ("SERVER_IP", ""), ("SERVER_PORT", ""), ("REQUESTED_CAR", ""), ("NAME", name),
                                   ("TEAM", ""), ("GUID", ""), ("PASSWORD", "")]))
        }
        return text(ini)
    }

    /// video.ini for a first start: fullscreen at the guest screen's size and refresh (the guest
    /// monitor's own mode), no vertical sync (the app paces presents), and the cheaper settings a
    /// phone draws at a steady rate. The game's video settings change them later.
    public static func videoINI(width: Int, height: Int, refresh: Int) -> String {
        text([
            ("VIDEO", [("WIDTH", String(width)), ("HEIGHT", String(height)), ("REFRESH", String(refresh)), ("FULLSCREEN", "1"),
                       ("INDEX", "0"), ("VSYNC", "0"), ("AASAMPLES", "1"), ("AAQUALITY", "0"), ("ANISOTROPIC", "2"),
                       ("SHADOW_MAP_SIZE", "1024"), ("FPS_CAP_MS", "0"), ("DISABLE_LEGACY_HDR", "0")]),
            ("REFRESH", [("VALUE", String(refresh))]),
            ("CAMERA", [("MODE", "DEFAULT")]),
            ("ASSETTOCORSA", [("HIDE_ARMS", "0"), ("HIDE_STEER", "0"), ("LOCK_STEER", "0"), ("WORLD_DETAIL", "2")]),
            ("EFFECTS", [("MOTION_BLUR", "0"), ("RENDER_SMOKE_IN_MIRROR", "0"), ("SMOKE", "1"), ("FXAA", "0")]),
            ("POST_PROCESS", [("ENABLED", "0"), ("QUALITY", "0"), ("FILTER", "default"), ("GLARE", "0"), ("DOF", "0"),
                              ("RAYS_OF_GOD", "0"), ("HEAT_SHIMMER", "0"), ("FXAA", "0")]),
            ("MIRROR", [("SIZE", "512"), ("HQ", "0")]),
            ("CUBEMAP", [("SIZE", "256"), ("FACES_PER_FRAME", "1"), ("FARPLANE", "100")]),
            ("SATURATION", [("LEVEL", "100")]),
        ])
    }

    /// controls.ini for a first start: the first Xbox pad (XInput) steers with the left stick,
    /// with the triggers as throttle and brake; RB and LB shift up and down, B is the handbrake,
    /// Y changes camera, X sounds the horn, the D-pad's up the headlights and its others glance.
    public static let controlsINI: String = {
        func button(_ name: String, _ xbox: String) -> (String, [(String, String)]) {
            (name, [("JOY", "-1"), ("BUTTON", "-1"), ("KEY", "-1"), ("XBOXBUTTON", xbox)])
        }
        return text([
            ("HEADER", [("INPUT_METHOD", "X360")]),
            ("ADVANCED", [("COMBINE_WITH_KEYBOARD_CONTROL", "1")]),
            ("X360", [("STEER_THUMB", "LEFT"), ("STEER_GAMMA", "2"), ("STEER_FILTER", "0.5"), ("SPEED_SENSITIVITY", "0.4"),
                      ("STEER_DEADZONE", "0.05"), ("STEER_SPEED", "0.3"), ("RUMBLE_INTENSITY", "0.5"), ("JOYPAD_INDEX", "0")]),
            button("GEARUP", "RSHOULDER"),
            button("GEARDN", "LSHOULDER"),
            ("HANDBRAKE", [("JOY", "-1"), ("BUTTON", "-1"), ("AXLE", "-1"), ("KEY", "-1"), ("XBOXBUTTON", "B"),
                           ("MIN", "-1"), ("MAX", "1"), ("GAMMA", "1")]),
            button("ACTION_CHANGE_CAMERA", "Y"),
            button("ACTION_HORN", "X"),
            button("ACTION_HEADLIGHTS", "DPAD_UP"),
            button("GLANCELEFT", "DPAD_LEFT"),
            button("GLANCERIGHT", "DPAD_RIGHT"),
            button("GLANCEBACK", "DPAD_DOWN"),
            ("SHIFTER", [("ACTIVE", "0"), ("JOY", "-1")]),
        ])
    }()

    /// assists.ini for a first start: what a pad needs to drive (automatic gears and clutch, the
    /// car's ABS and traction control), damage off. A server's rules still win online.
    public static let assistsINI: String = text([
        ("ASSISTS", [("IDEAL_LINE", "0"), ("AUTO_BLIP", "1"), ("STABILITY_CONTROL", "0"), ("AUTO_BRAKE", "0"),
                     ("AUTO_SHIFTER", "1"), ("ABS", "1"), ("TRACTION_CONTROL", "1"), ("AUTO_CLUTCH", "1"),
                     ("VISUALDAMAGE", "0"), ("DAMAGE", "0"), ("FUEL_RATE", "1"), ("TYRE_WEAR", "1"), ("TYRE_BLANKETS", "1"),
                     ("SLIPSTREAM", "1")]),
    ])

    /// Sections of `key=value` lines, CRLF as the game's own files.
    static func text(_ sections: [(String, [(String, String)])]) -> String {
        sections.map { name, values in
            "[\(name)]\r\n" + values.map { "\($0.0)=\($0.1)\r\n" }.joined()
        }.joined(separator: "\r\n")
    }

    /// Before Play: race.ini for `session`, and video.ini, controls.ini and assists.ini where
    /// `cfg` has none. Returns the names it wrote.
    @discardableResult
    public static func prepareForPlay(_ session: Session, cfg: URL, screen: (width: Int, height: Int), refresh: Int) throws -> [String] {
        try InstallFS.makeDirectory(cfg)
        var written = ["race.ini"]
        try InstallFS.writeAtomically(cfg.appendingPathComponent("race.ini"), Data(raceINI(session).utf8))
        let firstStart: [(String, String)] = [
            ("video.ini", videoINI(width: screen.width, height: screen.height, refresh: refresh)),
            ("controls.ini", controlsINI),
            ("assists.ini", assistsINI),
        ]
        let present = Set(((try? FileManager.default.contentsOfDirectory(atPath: cfg.path)) ?? []).map { $0.lowercased() })
        for (name, body) in firstStart where !present.contains(name) {
            try InstallFS.writeAtomically(cfg.appendingPathComponent(name), Data(body.utf8))
            written.append(name)
        }
        return written
    }
}
