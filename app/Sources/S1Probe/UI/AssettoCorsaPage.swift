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
        let left = plan.skipped > 0 ? " \(plan.skipped) file\(plan.skipped == 1 ? "" : "s") outside it (readmes, pictures) stay out." : ""
        PadModal.shared.picker(
            title: "Install \(url.lastPathComponent)?", context: "Assetto Corsa",
            note: "\(plan.summary): \(plan.files.count) file\(plan.files.count == 1 ? "" : "s"), \(ByteCount.format(plan.totalBytes)), "
                + "into the game's folder. A file already there with the same name is replaced.\(left) Keep Playport open until it is done.",
            options: [PadOption(id: "install", label: "Install"), PadOption(id: "cancel", label: "Cancel")],
            selected: nil) { choice in
            guard choice == "install" else { return }
            self.install(plan, from: source, url: url, into: root)
        }
    }

    private func install(_ plan: AssettoCorsaMods.Plan, from source: ImportSource, url: URL, into root: URL) {
        guard installing == nil else { return }
        installing = (plan.summary, 0)
        Self.log("installing \(url.lastPathComponent): \(plan.summary), \(plan.files.count) files, \(plan.totalBytes) bytes, "
                 + "\(plan.skipped) left out")
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
                Self.log("server \(address.text) (\(ip)): \(info.name), track \(info.track), \(info.cars.count) car(s), TCP \(info.tcpPort)"
                         + (info.clients.map { ", \($0) of \(info.capacity ?? 0) drivers" } ?? ""))
                session = AssettoCorsa.online(chosen, info: info, address: address, ip: ip, content: content, driverName: driver,
                                              steamID: account?.steamID, skins: skins)
            } catch {
                Self.log("server \(address.text): \(error)")
                tell("Can't reach the server", "\(address.text) did not give its information: \(AssettoCorsaServer.describe(error)) "
                     + "Check the address and its HTTP port, or clear Server in Game options to practise.")
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
            Self.log("\(s.summary); wrote \(names.joined(separator: ", ")) (screen \(size.0)x\(size.1) at \(refresh) Hz)"
                     + (s.online.map { $0.guid.isEmpty ? "; no SteamID for GUID" : "; GUID is the paired account's" } ?? ""))
        case let .failure(e):
            Self.log("race.ini not written: \(e)")
            tell("Can't start \(t.name)", "Playport couldn't write the game's race.ini: \(e)")
            return refused
        }
        let note = s.online.map { o in "Joining \(o.name.isEmpty ? "\(o.ip):\(o.tcpPort)" : o.name) with \(s.car)." }
        return (true, note)
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

struct AssettoCorsaOptionRows: View {
    let title: InstalledTitle
    /// The game's name, the pickers' context.
    let context: String
    @ObservedObject private var store = AssettoCorsaStore.shared
    @ObservedObject private var launch = TitleLaunch.shared
    @State private var content = AssettoCorsa.Content(cars: [], tracks: [])

    var body: some View {
        let o = store.options
        let server = o.server.trimmingCharacters(in: .whitespaces)
        VStack(spacing: 2) {
            PadSectionHeader(text: "Assetto Corsa").id("assetto")
            if let entry = LaunchSettingsStore.compat.entry(for: title.id) {
                PadRow(id: "opt:acHow", title: "\(OptionValue.compatMarker) How Play starts this game", subtitle: entry.reason,
                       subtitleLines: nil, style: .plain, hint: "Info") {}
            }
            PadRow(id: "opt:acServer", title: "Server",
                   subtitle: server.isEmpty ? "None: Play starts a practice session" : "Play joins it, as your Steam account",
                   value: server.isEmpty ? "None" : server, accessory: .chevron, changed: !server.isEmpty, style: .plain,
                   hint: "Edit", reset: server.isEmpty ? nil : { store.options.server = "" }) {
                PadModal.shared.keyboard(title: "Server", text: o.server, placeholder: "Address:HTTP port, or a join link",
                                         maxLength: 300) { store.options.server = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            PadRow(id: "opt:acPassword", title: "Server password", value: o.password.isEmpty ? "None" : "Set", accessory: .chevron,
                   changed: !o.password.isEmpty, style: .plain, hint: "Edit",
                   reset: o.password.isEmpty ? nil : { store.options.password = "" }) {
                PadModal.shared.keyboard(title: "Server password", text: o.password, placeholder: "Password", maxLength: 64,
                                         privacy: .hidden) { store.options.password = $0 }
            }
            PadRow(id: "opt:acDriver", title: "Driver name", value: o.driverName.isEmpty ? "Your Steam name" : o.driverName,
                   accessory: .chevron, changed: !o.driverName.isEmpty, style: .plain, hint: "Edit",
                   reset: o.driverName.isEmpty ? nil : { store.options.driverName = "" }) {
                PadModal.shared.keyboard(title: "Driver name", text: o.driverName, placeholder: "Your Steam name", maxLength: 32) {
                    store.options.driverName = $0.trimmingCharacters(in: .whitespaces)
                }
            }
            PadRow(id: "opt:acCar", title: "Car",
                   subtitle: server.isEmpty ? nil : "On a server, when it allows this car; else the first of its cars here",
                   value: o.car.isEmpty ? "First installed" : o.car, accessory: .chevron, changed: !o.car.isEmpty, style: .plain,
                   reset: o.car.isEmpty ? nil : { store.options.car = "" }) {
                PadModal.shared.picker(
                    title: "Car", context: "\(context) · Assetto Corsa", note: "\(content.cars.count) cars in content\\cars.",
                    options: [PadOption(id: "", label: "Default", detail: content.cars.first.map { "\($0), the first" })]
                        + content.cars.map { PadOption(id: $0, label: $0) },
                    selected: o.car) { store.options.car = $0 }
            }
            PadRow(id: "opt:acTrack", title: "Practice track", subtitle: "A server chooses its own",
                   value: o.track.isEmpty ? "First installed" : o.track, accessory: .chevron, changed: !o.track.isEmpty,
                   style: .plain, reset: o.track.isEmpty ? nil : { store.options.track = "" }) {
                let choices = content.trackChoices
                PadModal.shared.picker(
                    title: "Practice track", context: "\(context) · Assetto Corsa",
                    note: "\(content.tracks.count) tracks in content\\tracks; a layout is track/layout.",
                    options: [PadOption(id: "", label: "Default", detail: choices.first.map { "\($0), the first" })]
                        + choices.map { PadOption(id: $0, label: $0) },
                    selected: o.track) { store.options.track = $0 }
            }
            PadRow(id: "opt:acMods", title: "Install mods",
                   subtitle: "A .zip or folder from Files: Custom Shaders Patch, cars, tracks, a server's content pack",
                   value: installValue, accessory: .chevron, style: .plain, hint: "Pick") {
                guard store.installing == nil, !launch.running else { return }
                AssettoCorsaStore.pickRequests.send()
            }
        }
        .task(id: store.installs) {
            let root = LibraryModel.paths.games.appendingPathComponent(title.installDir, isDirectory: true)
            content = await Task.detached(priority: .userInitiated) { AssettoCorsa.content(root: root) }.value
        }
    }

    private var installValue: String {
        if let i = store.installing { return "Installing… \(Int(i.fraction * 100))%" }
        return store.lastInstall ?? "\(content.cars.count) cars, \(content.tracks.count) tracks"
    }
}
