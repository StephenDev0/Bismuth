// swift-tools-version: 6.0
import PackageDescription

// Release builds of the core spend about half their time in Swift's dynamic exclusivity checks.
// Set BISMUTH_FAST=1 (the build scripts do) to compile the emulation targets without them.
// It is opt-in because unsafe flags stop a package from being consumed as a versioned dependency.
let fast = Context.environment["BISMUTH_FAST"] == "1"
let coreSettings: [SwiftSetting] = fast
    ? [.unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))]
    : []

let package = Package(
    name: "Bismuth",
    platforms: [
        .macOS(.v13),
        .iOS(.v15),
        .tvOS(.v15),
    ],
    products: [
        // The emulator: CPU, PPU, APU, mappers, input (pads, Zapper, Four Score), save states, cheats.
        .library(name: "NESCore", targets: ["NESCore"]),
        // Metal presentation (MTKView + SwiftUI view, palette lookup and filters on the GPU).
        .library(name: "NESMetal", targets: ["NESMetal"]),
        // RetroAchievements helpers: rcheevos game hash, side-effect-free memory reads, hardcore guard.
        .library(name: "NESAchievements", targets: ["NESAchievements"]),
        // The libretro core (RetroArch and other libretro frontends).
        .library(name: "bismuth_libretro", type: .dynamic, targets: ["NESLibretro"]),
        .executable(name: "bismuth-cli", targets: ["bismuth-cli"]),
        .executable(name: "BismuthPlayer", targets: ["BismuthPlayer"]),
    ],
    targets: [
        .target(name: "NESCore", swiftSettings: coreSettings),
        .target(name: "NESAchievements", dependencies: ["NESCore"], swiftSettings: coreSettings),
        .target(name: "CLibretro", publicHeadersPath: "include"),
        .target(name: "NESLibretro", dependencies: ["NESCore", "NESAchievements", "CLibretro"], swiftSettings: coreSettings),
        .target(name: "NESMetal", dependencies: ["NESCore"]),
        .executableTarget(name: "bismuth-cli", dependencies: ["NESCore", "NESAchievements"]),
        .executableTarget(name: "BismuthPlayer", dependencies: ["NESCore", "NESMetal"]),
        .testTarget(name: "NESCoreTests", dependencies: ["NESCore", "NESAchievements"]),
        .testTarget(name: "NESLibretroTests", dependencies: ["NESLibretro", "CLibretro", "NESCore"]),
        .testTarget(name: "NESMetalTests", dependencies: ["NESMetal", "NESCore"]),
    ]
)
