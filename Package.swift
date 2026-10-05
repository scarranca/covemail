// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "Cove",
  // The Mac app supports macOS 14+. The iPhone app (CoveMobile, built by the Xcode project in iOS/)
  // starts at iOS 26, where the Foundation Models framework behind Apple Intelligence always exists.
  platforms: [.macOS(.v14), .iOS("26.0")],
  products: [
    .executable(name: "Cove", targets: ["Cove"]),
    .library(name: "CoveMobile", targets: ["CoveMobile"]),
    // The iPhone notification extension links only the shared core.
    .library(name: "CoveCore", targets: ["CoveCore"]),
  ],
  dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "CoveCore", dependencies: ["CSQLite"],
      // Foundation Models (Apple Intelligence) only exists from macOS 26; weak-link it so Cove still
      // launches on macOS 14 and 15, where `AppleIntelligence` reports itself unavailable.
      linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"],
                                    .when(platforms: [.macOS]))]),
    .executableTarget(name: "Cove", dependencies: [
        "CoveCore", .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
      ],
      resources: [.process("Resources")],
      linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    // The iPhone app's screens and state. Every file is iOS-only (`#if os(iOS)`); the Xcode app target
    // in iOS/ is a thin shell around it.
    .target(name: "CoveMobile", dependencies: ["CoveCore"], resources: [.process("Resources")]),
    .testTarget(name: "CoveCoreTests", dependencies: ["CoveCore"]),
    .testTarget(name: "CoveRenderingTests", dependencies: ["Cove", "CoveCore"]),
  ])
