// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// CI only (.github/ci/typecheck-app.sh puts this file over app/Package.swift in the runner's
// checkout, then puts the app's back): the release app's Swift module, Playport, compiled for
// iOS before the native build, so that a Swift error fails the job in minutes, not hours. It has
// the app target's own C and Swift targets as app/Package.swift declares them, without what the
// native build makes: no staged frameworks (KosmicKrisp, Mesa, StikJIT), no archives to link, no
// JIT helper extension. Keep its targets in step with app/Package.swift's release variant.
let package = Package(
    name: "Playport",
    platforms: [
        .iOS("26.0"),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Playport", targets: ["Playport"]),
    ],
    dependencies: [
        .package(path: "HostIOKit"),
        .package(path: "SteamClient"),
        .package(path: "GOGClient"),
        .package(path: "EpicClient"),
        .package(path: "BattleNetClient"),
        .package(path: "PlayportKit"),
    ],
    targets: [
        .target(name: "WineHost", cSettings: [.define("PLAYPORT_RELEASE")]),
        .target(name: "WinIOS", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .target(name: "HostIO", dependencies: ["WinIOS"]),
        .target(name: "SharedMemory", cSettings: [.unsafeFlags(["-fobjc-arc", "-O2"])]),
        .target(name: "JITHelperXPC", dependencies: ["SharedMemory"], swiftSettings: [.define("PLAYPORT_RELEASE")]),
        .target(name: "Relaunch"),
        .target(
            name: "Playport",
            dependencies: ["WineHost", "WinIOS", "HostIO", "JITHelperXPC",
                           .product(name: "HostIOKit", package: "HostIOKit"),
                           .product(name: "SteamClientKit", package: "SteamClient"),
                           .product(name: "GOGClientKit", package: "GOGClient"),
                           .product(name: "EpicClientKit", package: "EpicClient"),
                           .product(name: "BattleNetClientKit", package: "BattleNetClient"),
                           .product(name: "PlayportKit", package: "PlayportKit"),
                           "Relaunch", "SharedMemory"],
            path: "Sources/S1Probe",
            exclude: ["Runtime", "Dev"],
            swiftSettings: [.define("PLAYPORT_RELEASE")]
        ),
    ]
)
