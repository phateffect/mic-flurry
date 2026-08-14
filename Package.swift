// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "MicFlurryCore",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "MicFlurryDomain", targets: ["MicFlurryDomain"]),
    .library(name: "MicFlurryATVV", targets: ["MicFlurryATVV"]),
    .library(name: "MicFlurryAudio", targets: ["MicFlurryAudio"]),
    .library(name: "MicFlurryBluetooth", targets: ["MicFlurryBluetooth"]),
    .library(name: "MicFlurryStorage", targets: ["MicFlurryStorage"]),
    .library(name: "MicFlurryControl", targets: ["MicFlurryControl"]),
    .library(name: "MicFlurryHIDProtocol", targets: ["MicFlurryHIDProtocol"]),
    .library(name: "MicFlurryHIDHelperCore", targets: ["MicFlurryHIDHelperCore"]),
    .library(name: "MicFlurryHIDClient", targets: ["MicFlurryHIDClient"]),
    .library(name: "MicFlurryDaemonCore", targets: ["MicFlurryDaemonCore"]),
    .executable(name: "micflurryd", targets: ["MicFlurryDaemon"]),
    .executable(name: "micflurry-hid-helper", targets: ["MicFlurryHIDHelper"]),
    .executable(name: "micflurry-service-host", targets: ["MicFlurryServiceHost"]),
  ],
  targets: [
    .target(name: "MicFlurryDomain"),
    .target(name: "MicFlurryATVV", dependencies: ["MicFlurryDomain"]),
    .target(
      name: "MicFlurryAudio",
      dependencies: ["MicFlurryDomain"],
      linkerSettings: [
        .linkedFramework("AudioToolbox"),
        .linkedFramework("CoreAudio"),
      ]
    ),
    .target(
      name: "MicFlurryBluetooth",
      dependencies: ["MicFlurryDomain", "MicFlurryATVV"],
      linkerSettings: [
        .linkedFramework("CoreBluetooth"),
        .linkedFramework("IOKit"),
      ]
    ),
    .target(
      name: "MicFlurryStorage",
      dependencies: ["MicFlurryDomain"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
      name: "MicFlurryControl",
      dependencies: ["MicFlurryDomain"]
    ),
    .target(
      name: "MicFlurryHIDProtocol",
      dependencies: ["MicFlurryDomain"],
      resources: [.copy("Resources/device-profiles.json")]
    ),
    .target(
      name: "MicFlurryHIDHelperCore",
      dependencies: ["MicFlurryHIDProtocol"],
      linkerSettings: [
        .linkedFramework("IOKit"),
        .linkedFramework("SystemConfiguration"),
      ]
    ),
    .target(
      name: "MicFlurryHIDClient",
      dependencies: ["MicFlurryHIDProtocol"]
    ),
    .target(
      name: "MicFlurryDaemonCore",
      dependencies: [
        "MicFlurryDomain",
        "MicFlurryATVV",
        "MicFlurryAudio",
        "MicFlurryBluetooth",
        "MicFlurryControl",
        "MicFlurryHIDClient",
        "MicFlurryStorage",
      ],
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("CoreGraphics"),
      ]
    ),
    .executableTarget(
      name: "MicFlurryDaemon",
      dependencies: [
        "MicFlurryBluetooth",
        "MicFlurryDaemonCore",
        "MicFlurryControl",
        "MicFlurryHIDProtocol",
      ]
    ),
    .executableTarget(
      name: "MicFlurryHIDHelper",
      dependencies: ["MicFlurryHIDHelperCore", "MicFlurryHIDProtocol"]
    ),
    .executableTarget(
      name: "MicFlurryServiceHost",
      linkerSettings: [.linkedFramework("ServiceManagement")]
    ),
    .testTarget(name: "MicFlurryDomainTests", dependencies: ["MicFlurryDomain"]),
    .testTarget(name: "MicFlurryATVVTests", dependencies: ["MicFlurryATVV"]),
    .testTarget(name: "MicFlurryAudioTests", dependencies: ["MicFlurryAudio"]),
    .testTarget(name: "MicFlurryStorageTests", dependencies: ["MicFlurryStorage"]),
    .testTarget(
      name: "MicFlurryDaemonCoreTests",
      dependencies: ["MicFlurryDaemonCore"]
    ),
    .testTarget(
      name: "MicFlurryControlTests",
      dependencies: ["MicFlurryControl"]
    ),
    .testTarget(
      name: "MicFlurryHIDHelperCoreTests",
      dependencies: ["MicFlurryHIDHelperCore", "MicFlurryHIDProtocol"]
    ),
    .testTarget(
      name: "MicFlurryHIDClientTests",
      dependencies: ["MicFlurryHIDClient", "MicFlurryHIDProtocol"]
    ),
  ]
)
