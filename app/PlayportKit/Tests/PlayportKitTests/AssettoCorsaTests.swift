// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SteamClientKit
import XCTest
@testable import PlayportKit

final class AssettoCorsaTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("assetto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var games: URL { root.appendingPathComponent("Games") }
    private var ac: URL { games.appendingPathComponent("assettocorsa") }

    private func file(_ rel: String, under base: URL? = nil, _ text: String = "x") throws {
        let url = (base ?? games).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func receipt(app: UInt32, dir: String, executable: String?) throws -> InstallReceipt {
        let exe = executable.map { #","executable":"\#($0)","arguments":"-launcher""# } ?? ""
        let json = """
        {"appID":\(app),"name":"Assetto Corsa","installDir":"\(dir)","buildID":7,"depots":[{"depotID":\(app + 1),"gid":42}],
         "files":2,"bytes":1234,"skippedDepots":[],"skippedSymlinks":0,"installedAt":"2026-09-24T00:00:00Z"\(exe)}
        """
        return try JSONDecoder().decode(InstallReceipt.self, from: Data(json.utf8))
    }

    // MARK: the compatibility default

    func testTheShippedTableStartsAssettoCorsaWithoutItsLauncher() throws {
        let table = try CompatDefaults.load(directory: CompatDefaultsTests.shipped)
        let entry = try XCTUnwrap(table.entry(for: AssettoCorsa.titleID))
        XCTAssertEqual(entry.executable, "acs.exe")
        XCTAssertEqual(entry.controls, .gamepad)
        XCTAssertEqual(table.executables[AssettoCorsa.titleID], "acs.exe")
        XCTAssertNil(table.entry(for: "epic-Buffalo")?.executable)
    }

    func testAnEntryMayNameOnlyAnExecutableAndABadOneIsRefused() throws {
        let only = try CompatDefaults.parse(Data(#"{"titles":{"app-1":{"executable":"bin\\x64\\game.exe","reason":"Why."}}}"#.utf8))
        XCTAssertEqual(only.entry(for: "app-1")?.executable, #"bin\x64\game.exe"#)
        XCTAssertEqual(only.entry(for: "app-1")?.settings, LaunchSettings())
        for bad in [#""..\\game.exe""#, #""C:\\game.exe""#, #""game.dll""#, #""""#, #"".exe""#, #""bin\\\\game.exe""#, "3", #"["a.exe"]"#] {
            let json = #"{"titles":{"app-1":{"executable":\#(bad),"reason":"Why."}}}"#
            XCTAssertThrowsError(try CompatDefaults.parse(Data(json.utf8)), bad) {
                XCTAssertEqual($0 as? CompatDefaultsError, .badSetting("app-1.executable"), bad)
            }
        }
    }

    /// Steam's launch entry (the .NET launcher) gives way to the entry's acs.exe when it is in the
    /// folder, with none of the entry's arguments; without acs.exe the receipt's stays.
    func testAdoptionStartsTheCompatibilityExecutableInPlaceOfTheReceipts() throws {
        try file("assettocorsa/AssettoCorsa.exe")
        try file("assettocorsa/acs.exe")
        let r = try receipt(app: AssettoCorsa.appID, dir: "assettocorsa", executable: "AssettoCorsa.exe")
        let pinned = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [r], previous: Catalog(),
                                   compatExecutables: ["app-244210": "ACS.EXE"])
        let t = try XCTUnwrap(pinned.title(id: AssettoCorsa.titleID))
        XCTAssertEqual(t.executable, "acs.exe")
        XCTAssertNil(t.storeArguments)
        let plain = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [r], previous: Catalog())
        XCTAssertEqual(plain.title(id: AssettoCorsa.titleID)?.executable, "AssettoCorsa.exe")
        XCTAssertEqual(plain.title(id: AssettoCorsa.titleID)?.storeArguments, ["-launcher"])
        try FileManager.default.removeItem(at: ac.appendingPathComponent("acs.exe"))
        let gone = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [r], previous: Catalog(),
                                 compatExecutables: ["app-244210": "acs.exe"])
        XCTAssertEqual(gone.title(id: AssettoCorsa.titleID)?.executable, "AssettoCorsa.exe")
    }

    // MARK: servers

    func testServerAddressesAndJoinLinksRead() {
        XCTAssertEqual(AssettoCorsa.serverAddress(" 157.90.1.2:8081 "), .init(host: "157.90.1.2", httpPort: 8081))
        XCTAssertEqual(AssettoCorsa.serverAddress("srv.example.org:9680"), .init(host: "srv.example.org", httpPort: 9680))
        XCTAssertEqual(AssettoCorsa.serverAddress("acmanager://race/online/join?ip=1.2.3.4&httpPort=8090"),
                       .init(host: "1.2.3.4", httpPort: 8090))
        XCTAssertEqual(AssettoCorsa.serverAddress("https://acstuff.club/s/q:race/online/join?ip=5.6.7.8&httpPort=8082"),
                       .init(host: "5.6.7.8", httpPort: 8082))
        for bad in ["", "1.2.3.4", "1.2.3.4:0", "1.2.3.4:70000", "a b:80", ":80", "x;y:80", "acmanager://race/online/join?ip=1.2.3.4",
                    "https://example.org/?httpPort=8081"] {
            XCTAssertNil(AssettoCorsa.serverAddress(bad), bad)
        }
    }

    func testServerInfoReadsKunosAndAssettoServerAnswers() throws {
        let kunos = try AssettoCorsa.serverInfo(Data("""
        {"ip":"","port":9600,"tport":9601,"uport":9600,"name":"Test; server","clients":3,"maxclients":24,
         "track":"ks_nordschleife-endurance","cars":["ks_mazda_mx5_cup","bmw_m3_e30"],"pass":false}
        """.utf8))
        XCTAssertEqual(kunos, .init(name: "Test  server", track: "ks_nordschleife-endurance", cars: ["ks_mazda_mx5_cup", "bmw_m3_e30"],
                                    tcpPort: 9601, needsPassword: false, clients: 3, capacity: 24))
        let noTCP = try AssettoCorsa.serverInfo(Data(#"{"port":9600,"track":"monza","cars":[],"pass":true}"#.utf8))
        XCTAssertEqual(noTCP.tcpPort, 9600)
        XCTAssertTrue(noTCP.needsPassword)
        XCTAssertThrowsError(try AssettoCorsa.serverInfo(Data(#"{"tport":9600}"#.utf8)))
        XCTAssertThrowsError(try AssettoCorsa.serverInfo(Data(#"{"track":"monza"}"#.utf8)))
        XCTAssertThrowsError(try AssettoCorsa.serverInfo(Data("<html>".utf8)))
    }

    func testHTTPBodiesAreJoinedAndRefused() throws {
        let plain = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\n{}{}trailing"
        XCTAssertEqual(try AssettoCorsa.httpBody(Data(plain.utf8)), Data("{}{}".utf8))
        let chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n{\"a\r\n4;x=y\r\n\":1}\r\n0\r\n\r\n"
        XCTAssertEqual(try AssettoCorsa.httpBody(Data(chunked.utf8)), Data("{\"a\":1}".utf8))
        let closed = "HTTP/1.0 200 OK\r\n\r\n{\"b\":2}"
        XCTAssertEqual(try AssettoCorsa.httpBody(Data(closed.utf8)), Data("{\"b\":2}".utf8))
        XCTAssertThrowsError(try AssettoCorsa.httpBody(Data("HTTP/1.1 404 Not Found\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? AssettoCorsa.ServerError, .http(404))
        }
        XCTAssertThrowsError(try AssettoCorsa.httpBody(Data("SSH-2.0-OpenSSH\r\n".utf8))) {
            XCTAssertEqual($0 as? AssettoCorsa.ServerError, .notHTTP)
        }
        XCTAssertTrue(String(decoding: AssettoCorsa.infoRequest(.init(host: "1.2.3.4", httpPort: 8081)), as: UTF8.self)
            .hasPrefix("GET /INFO HTTP/1.1\r\nHost: 1.2.3.4:8081\r\n"))
    }

    func testAServersCustomShadersPatchPrefixComesOff() {
        XCTAssertEqual(AssettoCorsa.serverTrack("csp/2144/../shuto_revival_project_beta").id, "shuto_revival_project_beta")
        XCTAssertEqual(AssettoCorsa.serverTrack("csp/2144/../shuto_revival_project_beta").cspBuild, 2144)
        XCTAssertEqual(AssettoCorsa.serverTrack("csp/3116/../E/../pk_freeroam").id, "pk_freeroam")
        XCTAssertEqual(AssettoCorsa.serverTrack("ks_nordschleife-endurance").id, "ks_nordschleife-endurance")
        XCTAssertNil(AssettoCorsa.serverTrack("monza").cspBuild)
    }

    // MARK: the session

    private func installContent() throws {
        try file("content/cars/ks_mazda_mx5_cup/data.acd", under: ac)
        try file("content/cars/ks_mazda_mx5_cup/skins/00_red/preview.jpg", under: ac)
        try file("content/cars/ks_mazda_mx5_cup/skins/01_blue/preview.jpg", under: ac)
        try file("content/cars/abarth500/data.acd", under: ac)
        try file("content/tracks/monza/data/surfaces.ini", under: ac)
        try file("content/tracks/ks_nordschleife/endurance/data/surfaces.ini", under: ac)
        try file("content/tracks/ks_nordschleife/nordschleife/data/surfaces.ini", under: ac)
        try file("content/tracks/ks_nordschleife/ui/endurance/ui_track.json", under: ac)
        try file("content/tracks/shuto_revival_project_beta/data/surfaces.ini", under: ac)
        try file("content/tracks/empty/readme.txt", under: ac)
    }

    func testTheContentListsCarsTracksAndLayouts() throws {
        try installContent()
        let c = AssettoCorsa.content(root: ac)
        XCTAssertEqual(c.cars, ["abarth500", "ks_mazda_mx5_cup"])
        XCTAssertEqual(c.tracks.map(\.id), ["ks_nordschleife", "monza", "shuto_revival_project_beta"])
        XCTAssertEqual(c.track("KS_NORDSCHLEIFE")?.layouts, ["endurance", "nordschleife"])
        XCTAssertEqual(c.track("ks_nordschleife")?.plain, false)
        XCTAssertEqual(c.trackChoices, ["ks_nordschleife/endurance", "ks_nordschleife/nordschleife", "monza", "shuto_revival_project_beta"])
        XCTAssertEqual(c.layout("monza").map { [$0.track, $0.layout] }, ["monza", ""])
        XCTAssertEqual(c.layout("ks_nordschleife").map { [$0.track, $0.layout] }, ["ks_nordschleife", "endurance"])
        XCTAssertNil(c.layout("ks_nordschleife/gp"))
        XCTAssertEqual(c.serverLayout("ks_nordschleife-nordschleife").map { [$0.track, $0.layout] }, ["ks_nordschleife", "nordschleife"])
        XCTAssertEqual(c.serverLayout("monza").map { [$0.track, $0.layout] }, ["monza", ""])
        XCTAssertNil(c.serverLayout("spa"))
        XCTAssertEqual(AssettoCorsa.skins(car: "KS_MAZDA_MX5_CUP", root: ac), ["00_red", "01_blue"])
        XCTAssertEqual(AssettoCorsa.content(root: root), .init(cars: [], tracks: []))
    }

    func testPracticeTakesTheChoiceOrTheFirstAndRefusesWhatIsGone() throws {
        try installContent()
        let c = AssettoCorsa.content(root: ac)
        let skins = { AssettoCorsa.skins(car: $0, root: self.ac) }
        let first = try AssettoCorsa.practice(.init(), content: c, driverName: "Player", skins: skins).get()
        XCTAssertEqual(first, .init(car: "abarth500", skin: "", track: "ks_nordschleife", layout: "endurance", driverName: "Player"))
        let chosen = try AssettoCorsa.practice(.init(car: "ks_mazda_mx5_cup", track: "monza"), content: c, driverName: "P", skins: skins).get()
        XCTAssertEqual([chosen.car, chosen.skin, chosen.track, chosen.layout], ["ks_mazda_mx5_cup", "00_red", "monza", ""])
        XCTAssertEqual(AssettoCorsa.practice(.init(track: "spa"), content: c, driverName: "P", skins: skins), .failure(.trackMissing("spa")))
        XCTAssertEqual(AssettoCorsa.practice(.init(), content: .init(cars: [], tracks: []), driverName: "P", skins: skins), .failure(.noCars))
        XCTAssertEqual(AssettoCorsa.practice(.init(), content: .init(cars: ["a"], tracks: []), driverName: "P", skins: skins),
                       .failure(.noTracks))
    }

    func testJoiningTakesTheServersTrackAndAChosenOrFirstCarItHas() throws {
        try installContent()
        let c = AssettoCorsa.content(root: ac)
        let skins = { AssettoCorsa.skins(car: $0, root: self.ac) }
        let address = AssettoCorsa.ServerAddress(host: "srv.example.org", httpPort: 8081)
        let info = AssettoCorsa.ServerInfo(name: "No Hesi", track: "csp/2144/../shuto_revival_project_beta",
                                           cars: ["missing_car", "KS_MAZDA_MX5_CUP", "abarth500"], tcpPort: 9600)
        let s = try AssettoCorsa.online(.init(password: "pw"), info: info, address: address, ip: "1.2.3.4", content: c,
                                        driverName: "Player", steamID: 76561198000000001, skins: skins).get()
        XCTAssertEqual(s.car, "KS_MAZDA_MX5_CUP")   // the server's spelling
        XCTAssertEqual(s.skin, "00_red")
        XCTAssertEqual([s.track, s.layout], ["shuto_revival_project_beta", ""])
        XCTAssertEqual(s.online, .init(ip: "1.2.3.4", tcpPort: 9600, httpPort: 8081, name: "No Hesi", password: "pw",
                                       guid: "76561198000000001"))
        let chosen = try AssettoCorsa.online(.init(car: "abarth500"), info: info, address: address, ip: "1.2.3.4", content: c,
                                             driverName: "P", steamID: nil, skins: skins).get()
        XCTAssertEqual(chosen.car, "abarth500")
        XCTAssertEqual(chosen.online?.guid, "")
        var other = info
        other.track = "spa"
        XCTAssertEqual(AssettoCorsa.online(.init(), info: other, address: address, ip: "1.2.3.4", content: c, driverName: "P",
                                           steamID: nil, skins: skins), .failure(.serverTrackMissing("spa")))
        other = info
        other.cars = ["x", "y"]
        XCTAssertEqual(AssettoCorsa.online(.init(), info: other, address: address, ip: "1.2.3.4", content: c, driverName: "P",
                                           steamID: nil, skins: skins), .failure(.serverCarsMissing(["x", "y"])))
    }

    func testRaceINIHoldsThePracticeOrTheServer() {
        let practice = AssettoCorsa.raceINI(.init(car: "abarth500", skin: "red", track: "ks_nordschleife", layout: "endurance",
                                                  driverName: "A;B\n"))
        let lines = practice.components(separatedBy: "\r\n")
        for want in ["[RACE]", "MODEL=abarth500", "SKIN=red", "TRACK=ks_nordschleife", "CONFIG_TRACK=endurance", "DRIVER_NAME=A B",
                     "[SESSION_0]", "NAME=Practice", "SPAWN_SET=PIT", "[REMOTE]", "ACTIVE=0"] {
            XCTAssertTrue(lines.contains(want), want)
        }
        XCTAssertFalse(practice.contains("\n\n"), "CRLF only")
        let online = AssettoCorsa.raceINI(.init(car: "abarth500", skin: "", track: "monza", layout: "", driverName: "P",
                                                online: .init(ip: "1.2.3.4", tcpPort: 9600, httpPort: 8081, name: "NH",
                                                              password: "", guid: "7656")))
        let o = online.components(separatedBy: "\r\n")
        for want in ["ACTIVE=1", "SERVER_IP=1.2.3.4", "SERVER_PORT=9600", "SERVER_HTTP_PORT=8081", "SERVER_NAME=NH",
                     "REQUESTED_CAR=abarth500", "GUID=7656", "NAME=Nothing"] {
            XCTAssertTrue(o.contains(want), want)
        }
        XCTAssertFalse(o.contains("SPAWN_SET=PIT"))
    }

    func testPrepareWritesRaceINIEachTimeAndTheOthersOnce() throws {
        let cfg = AssettoCorsa.cfgDirectory(userProfile: root.appendingPathComponent("users/playport"))
        XCTAssertTrue(cfg.path.hasSuffix("users/playport/Documents/Assetto Corsa/cfg"))
        let s = AssettoCorsa.Session(car: "a", skin: "", track: "monza", layout: "", driverName: "P")
        XCTAssertEqual(try AssettoCorsa.prepareForPlay(s, cfg: cfg, screen: (2622, 1206), refresh: 120),
                       ["race.ini", "video.ini", "controls.ini", "assists.ini"])
        let video = try String(contentsOf: cfg.appendingPathComponent("video.ini"), encoding: .utf8)
        XCTAssertTrue(video.contains("WIDTH=2622\r\nHEIGHT=1206\r\nREFRESH=120\r\nFULLSCREEN=1\r\n"))
        XCTAssertTrue(try String(contentsOf: cfg.appendingPathComponent("controls.ini"), encoding: .utf8)
            .hasPrefix("[HEADER]\r\nINPUT_METHOD=X360\r\n"))
        try FileManager.default.removeItem(at: cfg.appendingPathComponent("video.ini"))
        try Data("[VIDEO]\r\nWIDTH=1\r\n".utf8).write(to: cfg.appendingPathComponent("Video.INI"))
        var next = s
        next.car = "b"
        XCTAssertEqual(try AssettoCorsa.prepareForPlay(next, cfg: cfg, screen: (1280, 720), refresh: 60), ["race.ini"])
        XCTAssertTrue(try String(contentsOf: cfg.appendingPathComponent("race.ini"), encoding: .utf8).contains("MODEL=b\r\n"))
        XCTAssertEqual(try String(contentsOf: cfg.appendingPathComponent("Video.INI"), encoding: .utf8), "[VIDEO]\r\nWIDTH=1\r\n")
    }

    func testOptionsReadWithKeysMissing() throws {
        let o = try JSONDecoder().decode(AssettoCorsa.Options.self, from: Data(#"{"server":"1.2.3.4:8081"}"#.utf8))
        XCTAssertEqual(o, .init(server: "1.2.3.4:8081"))
        XCTAssertEqual(try JSONDecoder().decode(AssettoCorsa.Options.self, from: JSONEncoder().encode(o)), o)
    }
}

final class AssettoCorsaModsTests: XCTestCase {
    private func plan(_ paths: [String], name: String = "mod") throws -> AssettoCorsaMods.Plan {
        try AssettoCorsaMods.plan(paths.map { ($0, UInt64(10)) }, name: name)
    }

    func testCustomShadersPatchGoesToTheGamesFolder() throws {
        let p = try plan(["lights-patch/dwrite.dll", "lights-patch/extension/config/general.ini", "lights-patch/readme.txt",
                          "lights-patch/extension/shaders/a.fx", "__MACOSX/lights-patch/._dwrite.dll"])
        XCTAssertEqual(p.files.map(\.to), ["dwrite.dll", "extension/config/general.ini", "extension/shaders/a.fx"])
        XCTAssertTrue(p.shadersPatch)
        XCTAssertEqual(p.skipped, 1)
        XCTAssertEqual(p.summary, "Custom Shaders Patch")
        XCTAssertEqual(p.totalBytes, 30)
    }

    func testAContentPackGoesWhereItsContentFolderSays() throws {
        let p = try plan(["Pack v3/content/cars/nohesi_a/data.acd", "Pack v3/content/cars/nohesi_a/extension/ext_config.ini",
                          "Pack v3/content/tracks/srp/models.ini", "Pack v3/extension/config/tracks/srp.ini",
                          "Pack v3/steam_api64.dll", "Pack v3/install.txt", "other/readme.txt"])
        XCTAssertEqual(p.files.map(\.to), ["content/cars/nohesi_a/data.acd", "content/cars/nohesi_a/extension/ext_config.ini",
                                           "content/tracks/srp/models.ini", "extension/config/tracks/srp.ini"])
        XCTAssertEqual(p.cars, ["nohesi_a"])
        XCTAssertEqual(p.tracks, ["srp"])
        XCTAssertFalse(p.shadersPatch)
        XCTAssertEqual(p.skipped, 3)
        XCTAssertEqual(p.summary, "1 car (nohesi_a), 1 track (srp)")
    }

    func testCarsAndTracksFoldersGoUnderContent() throws {
        let p = try plan(["cars/bmw_m3/data.acd", "tracks/spa/data/surfaces.ini", "cars/readme.txt"])
        XCTAssertEqual(p.files.map(\.to), ["content/cars/bmw_m3/data.acd", "content/tracks/spa/data/surfaces.ini"])
    }

    func testACarOrTrackFolderIsFoundByWhatItHolds() throws {
        let car = try plan(["nohesi_supra/data.acd", "nohesi_supra/nohesi_supra.kn5", "nohesi_supra/skins/red/livery.png",
                            "nohesi_supra/extension/ext_config.ini", "README.md"])
        XCTAssertEqual(car.files.map(\.to), ["content/cars/nohesi_supra/data.acd", "content/cars/nohesi_supra/extension/ext_config.ini",
                                             "content/cars/nohesi_supra/nohesi_supra.kn5", "content/cars/nohesi_supra/skins/red/livery.png"])
        XCTAssertEqual(car.skipped, 1)
        let top = try plan(["data.acd", "ui/ui_car.json"], name: "my_car")
        XCTAssertEqual(top.files.map(\.to), ["content/cars/my_car/data.acd", "content/cars/my_car/ui/ui_car.json"])
        let track = try plan(["Track Pack/pk_freeroam/ui/freeroam/ui_track.json", "Track Pack/pk_freeroam/freeroam/data/surfaces.ini",
                              "Track Pack/pk_freeroam/pk_freeroam.kn5", "Track Pack/carB/data/car.ini"])
        XCTAssertEqual(track.tracks, ["pk_freeroam"])
        XCTAssertEqual(track.cars, ["carB"])
        XCTAssertTrue(track.files.map(\.to).contains("content/tracks/pk_freeroam/freeroam/data/surfaces.ini"))
        XCTAssertTrue(track.files.map(\.to).contains("content/cars/carB/data/car.ini"))
    }

    func testWhatIsNoModIsRefused() {
        XCTAssertThrowsError(try plan(["readme.txt", "pics/a.png"])) {
            XCTAssertEqual($0 as? AssettoCorsaMods.Refusal, .unknownLayout)
        }
        XCTAssertThrowsError(try plan(["__MACOSX/x", ".DS_Store"])) { XCTAssertEqual($0 as? AssettoCorsaMods.Refusal, .empty) }
        XCTAssertThrowsError(try plan(["content/cars/a/data.acd", "content/cars/A/data.acd"]))
        XCTAssertThrowsError(try plan(["content/cars/a:b/data.acd"]))
    }

    func testAnInstallWritesIntoTheFoldersThereInTheirSpelling() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("acmods-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let game = base.appendingPathComponent("assettocorsa"), mod = base.appendingPathComponent("Pack")
        for (rel, text) in [("Content/Cars/old/data.acd", "old"), ("DWRITE.DLL", "old")] {
            let url = game.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        for (rel, text) in [("content/cars/new/data.acd", "new car"), ("dwrite.dll", "csp"), ("extension/config/general.ini", "[A]")] {
            let url = mod.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let plan = try AssettoCorsaMods.plan(.folder(mod))
        XCTAssertEqual(plan.cars, ["new"])
        XCTAssertTrue(plan.shadersPatch)
        try AssettoCorsaMods.install(plan, from: .folder(mod), into: game, freeSpace: { _ in 1 << 40 })
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("Content/Cars/new/data.acd"), encoding: .utf8), "new car")
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("DWRITE.DLL"), encoding: .utf8), "csp")
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("extension/config/general.ini"), encoding: .utf8), "[A]")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: game.path).sorted(), ["Content", "DWRITE.DLL", "extension"])
        XCTAssertThrowsError(try AssettoCorsaMods.install(plan, from: .folder(mod), into: game, freeSpace: { _ in 1 })) {
            guard case .insufficientSpace? = $0 as? ImportError else { return XCTFail("\($0)") }
        }
    }
}
