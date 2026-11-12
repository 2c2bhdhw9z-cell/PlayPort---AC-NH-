// SPDX-License-Identifier: GPL-3.0-or-later
// Assetto Corsa's part of the game page and of Play (PlayportKit AssettoCorsa, AssettoCorsaMods).
// Game options › Assetto Corsa holds what every Play writes into race.ini: the server to join
// (none: a practice session), its password, the driver's name, the car and the practice track;
// and Install mods, a .zip or a folder picked in Files (the shell's one picker, AppShell) unpacked
// into the game's folder. Before each Play, LibraryModel.play asks prepareForPlay: with a server
// set, its HTTP port's /INFO (over a plain TCP connection: the servers answer HTTP, not HTTPS),
// then the session, race.ini and a first start's video, controls and assists files. The options
// are kept in UserDefaults, so they outlast an uninstall, as LaunchSettingsStore's do.

import Combine
import Foundation
import HostIOKit
import Network
import PlayportKit
import SteamClientKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class AssettoCorsaStore: ObservableObject {
    static let shared = AssettoCorsaStore()
    /// Install mods: the shell opens the Files picker (AppShell) and hands back what was picked (`picked`).
    static let pickRequests = PassthroughSubject<Void, Never>()
    static let contentTypes: [UTType] = [.zip, .folder]

    private static let key = "assettoCorsa.options"

    @Published var options: AssettoCorsa.Options { didSet { save() } }
    /// The install running now: what it installs and how far it is, 0 to 1.
    @Published private(set) var installing: (summary: String, fraction: Double)?
    /// The last install's outcome, for its row.
    @Published private(set) var lastInstall: String?
    /// Counts finished installs, so the page lists the cars and tracks again.
    @Published private(set) var installs = 0

    private init() {
        options = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(AssettoCorsa.Options.self, from: $0) } ?? AssettoCorsa.Options()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(options), forKey: Self.key)
    }

    nonisolated static func log(_ line: String) { LibraryModel.log("assetto corsa: " + line) }

    /// The prefix user's profile, `C:\users\playport`.
    nonisolated static let userProfile = WineHostRuntime.documents
        .appendingPathComponent("prefix/drive_c/users/playport", isDirectory: true)

    /// The game's folder in C:\Games, while it is installed.
    static func gameFolder() -> URL? {
        LibraryModel.shared.title(AssettoCorsa.titleID)
            .map { LibraryModel.paths.games.appendingPathComponent($0.installDir, isDirectory: true) }
    }

    /// The game's log and Custom Shaders Patch's, and the last race.ini, for Report a problem.
    nonisolated static func reportFiles() -> [URL] {
        let fm = FileManager.default
        let logs = AssettoCorsa.logsDirectory(userProfile: userProfile)
        let found = ((try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["txt", "log"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let race = AssettoCorsa.cfgDirectory(userProfile: userProfile).appendingPathComponent("race.ini")
        return (found + [race]).filter { fm.fileExists(atPath: $0.path) }
    }

    private func tell(_ title: String, _ note: String) {
        PadModal.shared.picker(title: title, context: "Assetto Corsa", note: note, options: [PadOption(id: "ok", label: "OK")],
                               selected: "ok") { _ in }
    }

    // MARK: Install mods

    /// What the Files picker returned: planned off the main thread, then the player confirms it,
    /// then it is unpacked into the game's folder, its progress on Install mods' row.
    func picked(_ url: URL) async {
        guard installing == nil else { return tell("An install is running", "Wait for it to finish, then pick the next one.") }
        guard let root = Self.gameFolder() else { return tell("Assetto Corsa is not installed", "Install the game first.") }
        guard !TitleLaunch.shared.running else { return }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
        let source: ImportSource = isDir ? .folder(url) : .zip(url)
        let planned = await Task.detached(priority: .userInitiated) { () -> Result<AssettoCorsaMods.Plan, Error> in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return Result { try AssettoCorsaMods.plan(source) }
        }.value
        let plan: AssettoCorsaMods.Plan
        switch planned {
        case let .success(p): plan = p
        case let .failure(e):
            Self.log("\(url.lastPathComponent) refused: \(e)")
            return tell("Can't install \(url.lastPathComponent)", (e as? AssettoCorsaMods.Refusal)?.description ?? "\(e)")
        }
        let name: String = url.lastPathComponent
        let files: String = Self.count(plan.files.count, "file")
        var note: String = plan.summary + ": " + files + ", " + ByteCount.format(plan.totalBytes) + ", into the game's folder. "
        note += "A file already there with the same name is replaced. "
        if plan.skipped > 0 { note += Self.count(plan.skipped, "file") + " outside it (readmes, pictures) stay out. " }
        note += "Keep Playport open until it is done."
        let options: [PadOption] = [PadOption(id: "install", label: "Install"), PadOption(id: "cancel", label: "Cancel")]
        let choose: (String) -> Void = { choice in
            guard choice == "install" else { return }
            self.install(plan, from: source, url: url, into: root)
        }
        PadModal.shared.picker(title: "Install " + name + "?", context: "Assetto Corsa", note: note, options: options,
                               selected: nil, choose: choose)
    }

    /// `1 file`, `3 files`.
    nonisolated static func count(_ n: Int, _ noun: String) -> String {
        String(n) + " " + noun + (n == 1 ? "" : "s")
    }

    private func install(_ plan: AssettoCorsaMods.Plan, from source: ImportSource, url: URL, into root: URL) {
        guard installing == nil else { return }
        installing = (plan.summary, 0)
        let line: String = "installing \(url.lastPathComponent): \(plan.summary), \(plan.files.count) files, "
        Self.log(line + "\(plan.totalBytes) bytes, \(plan.skipped) left out")
        let started = Date()
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    try AssettoCorsaMods.install(plan, from: source, into: root, progress: { p in
                        let fraction = p.bytesTotal == 0 ? 1 : Double(p.bytesDone) / Double(p.bytesTotal)
                        Task { @MainActor in AssettoCorsaStore.shared.progressed(fraction) }
                    })
                    return nil
                } catch let e as AssettoCorsaMods.Refusal {
                    return e.description
                } catch let e as ImportError {
                    return e.description
                } catch {
                    return "\(error)"
                }
            }.value
            installing = nil
            installs += 1
            if let failure {
                Self.log("install of \(url.lastPathComponent) stopped: \(failure)")
                lastInstall = "Stopped: \(url.lastPathComponent)"
                tell("\(url.lastPathComponent) was not installed", failure + " Files it wrote before it stopped stay.")
            } else {
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                Self.log("installed \(url.lastPathComponent) in \(seconds) s")
                lastInstall = "Installed \(plan.summary)"
                tell("Installed", "\(plan.summary) from \(url.lastPathComponent) is in the game's folder.")
            }
        }
    }

    private func progressed(_ fraction: Double) {
        if let i = installing { installing = (i.summary, fraction) }
    }

    // MARK: Play

    /// Before a Play of Assetto Corsa: the session the options ask for (a server's /INFO first), then
    /// race.ini and a first start's files. Not ready, with the reason on screen, when the game can't
    /// start; `note` is the launch screen's line for a server it joins.
    func prepareForPlay(_ t: InstalledTitle, screen: String?, steam: SteamService?) async -> (ready: Bool, note: String?) {
        let refused: (ready: Bool, note: String?) = (false, nil)
        guard installing == nil else {
            tell("Can't start \(t.name)", "Mods are being installed. Wait for the install to finish.")
            return refused
        }
        let chosen = options
        let root = LibraryModel.paths.games.appendingPathComponent(t.installDir, isDirectory: true)
        let account = await steam?.emulatorSettings(appID: AssettoCorsa.appID)
        let typed = chosen.driverName.trimmingCharacters(in: .whitespaces)
        let driver = typed.isEmpty ? (account?.personaName ?? "Player") : typed
        let content = await Task.detached(priority: .userInitiated) { AssettoCorsa.content(root: root) }.value
        let skins: (String) -> [String] = { AssettoCorsa.skins(car: $0, root: root) }
        let server = chosen.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let session: Result<AssettoCorsa.Session, AssettoCorsa.Refusal>
        if server.isEmpty {
            session = AssettoCorsa.practice(chosen, content: content, driverName: driver, skins: skins)
        } else {
            guard let address = AssettoCorsa.serverAddress(server) else {
                tell("Can't join the server", AssettoCorsa.Refusal.serverAddress(server).description)
                return refused
            }
            do {
                let (info, ip) = try await AssettoCorsaServer.info(address)
                var line: String = "server \(address.text) (\(ip)): \(info.name), track \(info.track), "
                line += "\(info.cars.count) car(s), TCP \(info.tcpPort)"
                if let clients = info.clients { line += ", \(clients) of \(info.capacity ?? 0) drivers" }
                Self.log(line)
                session = AssettoCorsa.online(chosen, info: info, address: address, ip: ip, content: content, driverName: driver,
                                              steamID: account?.steamID, skins: skins)
            } catch {
                Self.log("server \(address.text): \(error)")
                let why: String = AssettoCorsaServer.describe(error)
                let note: String = address.text + " did not give its information: " + why
                    + " Check the address and its HTTP port, or clear Server in Game options to practise."
                tell("Can't reach the server", note)
                return refused
            }
        }
        let s: AssettoCorsa.Session
        switch session {
        case let .success(found): s = found
        case let .failure(why):
            Self.log("not started: \(why)")
            tell("Can't start \(t.name)", why.description)
            return refused
        }
        let px = UIScreen.main.nativeBounds.size
        let size = Display.guestSize(panelLong: Int(px.width), panelShort: Int(px.height), spec: screen) ?? (1280, 720)
        let refresh = UIScreen.main.maximumFramesPerSecond
        let cfg = AssettoCorsa.cfgDirectory(userProfile: Self.userProfile)
        let written = await Task.detached(priority: .userInitiated) { () -> Result<[String], Error> in
            Result { try AssettoCorsa.prepareForPlay(s, cfg: cfg, screen: (width: size.0, height: size.1), refresh: refresh) }
        }.value
        switch written {
        case let .success(names):
            var line: String = "\(s.summary); wrote \(names.joined(separator: ", ")) (screen \(size.0)x\(size.1) at \(refresh) Hz)"
            if let o = s.online { line += o.guid.isEmpty ? "; no SteamID for GUID" : "; GUID is the paired account's" }
            Self.log(line)
        case let .failure(e):
            Self.log("race.ini not written: \(e)")
            tell("Can't start \(t.name)", "Playport couldn't write the game's race.ini: \(e)")
            return refused
        }
        guard let o = s.online else { return (true, nil) }
        let server: String = o.name.isEmpty ? "\(o.ip):\(o.tcpPort)" : o.name
        return (true, "Joining " + server + " with " + s.car + ".")
    }
}

// MARK: the server

/// A server's /INFO over one TCP connection (Network.framework), with the IPv4 address the
/// connection reached, which race.ini names for the game.
enum AssettoCorsaServer {
    static let timeout: TimeInterval = 8

    enum Failure: Error {
        case timedOut
        case tooLarge
    }

    static func info(_ address: AssettoCorsa.ServerAddress) async throws -> (AssettoCorsa.ServerInfo, String) {
        guard let port = NWEndpoint.Port(rawValue: address.httpPort) else { throw Failure.timedOut }
        let exchange = Exchange(NWConnection(host: NWEndpoint.Host(address.host), port: port, using: .tcp), fallbackIP: address.host)
        let (response, ip) = try await exchange.run(AssettoCorsa.infoRequest(address), timeout: timeout)
        return (try AssettoCorsa.serverInfo(try AssettoCorsa.httpBody(response)), ip)
    }

    /// For the player.
    static func describe(_ error: Error) -> String {
        switch error {
        case Failure.timedOut: "It did not answer in \(Int(timeout)) seconds."
        case Failure.tooLarge: "Its answer is too large to be a server's information."
        case let e as AssettoCorsa.ServerError: e.description
        case let e as NWError: e.localizedDescription + "."
        default: "\(error)."
        }
    }

    /// One request and its answer read to the end. Every handler runs on `queue`, which keeps the
    /// state; the continuation is resumed once, by the answer, an error or the timeout.
    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "playport.assetto-corsa.server")
        private var received = Data()
        private var ip: String
        private var continuation: CheckedContinuation<(Data, String), Error>?

        init(_ connection: NWConnection, fallbackIP: String) {
            self.connection = connection
            self.ip = fallbackIP
        }

        func run(_ request: Data, timeout: TimeInterval) async throws -> (Data, String) {
            try await withCheckedThrowingContinuation { c in
                queue.async {
                    self.continuation = c
                    self.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if case let .hostPort(host, _)? = self.connection.currentPath?.remoteEndpoint, case let .ipv4(a) = host {
                                self.ip = "\(a)"
                            }
                            self.connection.send(content: request, completion: .contentProcessed { error in
                                if let error { self.finish(.failure(error)) } else { self.receive() }
                            })
                        case let .failed(error), let .waiting(error):
                            self.finish(.failure(error))
                        default:
                            break
                        }
                    }
                    self.connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(Failure.timedOut)) }
                }
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, complete, error in
                if let data { self.received.append(data) }
                if self.received.count > 1 << 20 { return self.finish(.failure(Failure.tooLarge)) }
                if complete { return self.finish(.success(self.received)) }
                if let error { return self.finish(.failure(error)) }
                self.receive()
            }
        }

        private func finish(_ result: Result<Data, Error>) {
            guard let c = continuation else { return }
            continuation = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            let ip = self.ip
            c.resume(with: result.map { ($0, ip) })
        }
    }
}

// MARK: Game options › Assetto Corsa

extension InstalledTitle {
    /// Assetto Corsa's copy (Steam app 244210), whose page and Play have their own part here.
    var isAssettoCorsa: Bool { appID == AssettoCorsa.appID }
}

/// The rows, each its own small view: the type checker sees one row at a time.
struct AssettoCorsaOptionRows: View {
    let title: InstalledTitle
    /// The game's name, the pickers' context.
    let context: String
    @ObservedObject private var store = AssettoCorsaStore.shared
    @ObservedObject private var launch = TitleLaunch.shared
    @State private var content = AssettoCorsa.Content(cars: [], tracks: [])

    var body: some View {
        VStack(spacing: 2) {
            PadSectionHeader(text: "Assetto Corsa").id("assetto")
            howRow
            serverRow
            passwordRow
            driverRow
            carRow
            trackRow
            modsRow
        }
        .task(id: store.installs) { await list() }
    }

    private func list() async {
        let root: URL = LibraryModel.paths.games.appendingPathComponent(title.installDir, isDirectory: true)
        let found: AssettoCorsa.Content = await Task.detached(priority: .userInitiated) { AssettoCorsa.content(root: root) }.value
        content = found
    }

    @ViewBuilder private var howRow: some View {
        if let entry = LaunchSettingsStore.compat.entry(for: title.id) {
            let heading: String = OptionValue.compatMarker + " How Play starts this game"
            PadRow(id: "opt:acHow", title: heading, subtitle: entry.reason, subtitleLines: nil, style: .plain, hint: "Info",
                   action: {})
        }
    }

    private var serverRow: some View {
        let server: String = store.options.server
        let value: String = server.isEmpty ? "None" : server
        let subtitle: String = server.isEmpty ? "None: Play starts a practice session" : "Play joins it, as your Steam account"
        let reset: (() -> Void)? = server.isEmpty ? nil : { store.options.server = "" }
        return PadRow(id: "opt:acServer", title: "Server", subtitle: subtitle, value: value, accessory: .chevron,
                      changed: !server.isEmpty, style: .plain, hint: "Edit", reset: reset, action: { editServer() })
    }

    private func editServer() {
        let done: (String) -> Void = { text in store.options.server = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        PadModal.shared.keyboard(title: "Server", text: store.options.server, placeholder: "Address:HTTP port, or a join link",
                                 maxLength: 300, done: done)
    }

    private var passwordRow: some View {
        let set: Bool = !store.options.password.isEmpty
        let reset: (() -> Void)? = set ? { store.options.password = "" } : nil
        return PadRow(id: "opt:acPassword", title: "Server password", value: set ? "Set" : "None", accessory: .chevron,
                      changed: set, style: .plain, hint: "Edit", reset: reset, action: { editPassword() })
    }

    private func editPassword() {
        let done: (String) -> Void = { text in store.options.password = text }
        PadModal.shared.keyboard(title: "Server password", text: store.options.password, placeholder: "Password", maxLength: 64,
                                 privacy: .hidden, done: done)
    }

    private var driverRow: some View {
        let name: String = store.options.driverName
        let reset: (() -> Void)? = name.isEmpty ? nil : { store.options.driverName = "" }
        return PadRow(id: "opt:acDriver", title: "Driver name", value: name.isEmpty ? "Your Steam name" : name,
                      accessory: .chevron, changed: !name.isEmpty, style: .plain, hint: "Edit", reset: reset,
                      action: { editDriver() })
    }

    private func editDriver() {
        let done: (String) -> Void = { text in store.options.driverName = text.trimmingCharacters(in: .whitespaces) }
        PadModal.shared.keyboard(title: "Driver name", text: store.options.driverName, placeholder: "Your Steam name",
                                 maxLength: 32, done: done)
    }

    private var carRow: some View {
        let car: String = store.options.car
        let online: Bool = !store.options.server.trimmingCharacters(in: .whitespaces).isEmpty
        let subtitle: String? = online ? "On a server when it allows this car, else the first of its cars here" : nil
        let reset: (() -> Void)? = car.isEmpty ? nil : { store.options.car = "" }
        return PadRow(id: "opt:acCar", title: "Car", subtitle: subtitle, value: car.isEmpty ? "First installed" : car,
                      accessory: .chevron, changed: !car.isEmpty, style: .plain, reset: reset, action: { pickCar() })
    }

    private func pickCar() {
        let choose: (String) -> Void = { id in store.options.car = id }
        let note: String = String(content.cars.count) + " cars in content\\cars."
        PadModal.shared.picker(title: "Car", context: context + " · Assetto Corsa", note: note,
                               options: Self.options(content.cars), selected: store.options.car, choose: choose)
    }

    private var trackRow: some View {
        let track: String = store.options.track
        let reset: (() -> Void)? = track.isEmpty ? nil : { store.options.track = "" }
        return PadRow(id: "opt:acTrack", title: "Practice track", subtitle: "A server chooses its own",
                      value: track.isEmpty ? "First installed" : track, accessory: .chevron, changed: !track.isEmpty,
                      style: .plain, reset: reset, action: { pickTrack() })
    }

    private func pickTrack() {
        let choose: (String) -> Void = { id in store.options.track = id }
        let note: String = String(content.tracks.count) + " tracks in content\\tracks; a layout is track/layout."
        PadModal.shared.picker(title: "Practice track", context: context + " · Assetto Corsa", note: note,
                               options: Self.options(content.trackChoices), selected: store.options.track, choose: choose)
    }

    /// Default (the first), then each choice.
    private static func options(_ choices: [String]) -> [PadOption] {
        var detail: String?
        if let first = choices.first { detail = first + ", the first" }
        var out: [PadOption] = [PadOption(id: "", label: "Default", detail: detail)]
        for c in choices { out.append(PadOption(id: c, label: c)) }
        return out
    }

    private var modsRow: some View {
        PadRow(id: "opt:acMods", title: "Install mods",
               subtitle: "A .zip or folder from Files: Custom Shaders Patch, cars, tracks, a server's content pack",
               value: installValue, accessory: .chevron, style: .plain, hint: "Pick", action: { pickMods() })
    }

    private func pickMods() {
        guard store.installing == nil, !launch.running else { return }
        AssettoCorsaStore.pickRequests.send()
    }

    private var installValue: String {
        if let i = store.installing { return "Installing… " + String(Int(i.fraction * 100)) + "%" }
        if let last = store.lastInstall { return last }
        return String(content.cars.count) + " cars, " + String(content.tracks.count) + " tracks"
    }
}
