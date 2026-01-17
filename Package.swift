// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PirateRadio",
    products: [
        .library(
            name: "FMTransmitter",
            targets: ["FMTransmitter"]
        ),
        .executable(
            name: "pirate-radio",
            targets: ["PirateRadio"]
        ),
    ],
    targets: [
        // C++ библиотека fm_transmitter
        .target(
            name: "CFMTransmitter",
            path: "Sources/CFMTransmitter",
            sources: [
                "shim.cpp",
                "transmitter.cpp",
                "wave_reader.cpp",
                "mailbox.cpp"
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("."),
                .define("VERSION", to: "\"0.9.6\""),
                .define("EXECUTABLE", to: "\"fm_transmitter\""),
                .unsafeFlags(["-std=c++11", "-O3", "-Wall"]),
                // Raspberry Pi specific includes
                .unsafeFlags(["-I/opt/vc/include"], .when(platforms: [.linux])),
            ],
            linkerSettings: [
                // Raspberry Pi specific libraries
                .unsafeFlags(["-L/opt/vc/lib"], .when(platforms: [.linux])),
                .linkedLibrary("bcm_host", .when(platforms: [.linux])),
                .linkedLibrary("pthread"),
                .linkedLibrary("m"),
            ]
        ),

        // Swift обёртка над C++ библиотекой
        .target(
            name: "FMTransmitter",
            dependencies: ["CFMTransmitter"],
            path: "Sources/FMTransmitter"
        ),

        // CLI приложение
        .executableTarget(
            name: "PirateRadio",
            dependencies: ["FMTransmitter"],
            path: "Sources/PirateRadio"
        ),
    ],
    cxxLanguageStandard: .cxx11
)
