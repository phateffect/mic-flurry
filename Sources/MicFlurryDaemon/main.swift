import Dispatch
import Foundation
import MicFlurryBluetooth
import MicFlurryControl
import MicFlurryDaemonCore
import MicFlurryHIDClient

@main
@MainActor
enum MicFlurryDaemonMain {
  static func main() {
    do {
      let databaseURL = try databaseURL(arguments: CommandLine.arguments)
      let bluetooth = BluetoothAdapter()
      let runtime = try DaemonRuntime(
        databaseURL: databaseURL,
        keymapDirectory: FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".config/micflurry", isDirectory: true),
        bluetooth: bluetooth,
        hidClient: try hidClient()
      )
      let controlServer = UnixControlServer(
        socketURL: try socketURL(arguments: CommandLine.arguments),
        service: runtime
      )
      runtime.start()
      try controlServer.start()
      withExtendedLifetime((runtime, controlServer)) {
        dispatchMain()
      }
    } catch {
      FileHandle.standardError.write(Data("micflurryd: \(error)\n".utf8))
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func hidClient() throws -> HIDHelperClient? {
    let policy: HIDDaemonSecurityPolicy
    if let teamID = Bundle.main.object(forInfoDictionaryKey: "MicFlurryTeamIdentifier") as? String {
      policy = try HIDDaemonSecurityPolicy(teamID: teamID)
    } else {
      #if MICFLURRY_PRIVATE_DISTRIBUTION
        guard
          let helperCDHash = Bundle.main.object(
            forInfoDictionaryKey: "MicFlurryHIDHelperCDHash"
          ) as? String
        else { throw HIDHelperClientError.invalidCDHash }
        policy = try .privateAdHoc(helperCDHash: helperCDHash)
      #elseif DEBUG
        guard ProcessInfo.processInfo.environment["MICFLURRY_ALLOW_ADHOC_XPC"] == "1" else {
          return nil
        }
        policy = .developmentAdHoc
      #else
        return nil
      #endif
    }
    return HIDHelperClient(transport: HIDHelperXPCTransport(securityPolicy: policy))
  }

  private static func socketURL(arguments: [String]) throws -> URL {
    if let index = arguments.firstIndex(of: "--socket"), arguments.indices.contains(index + 1) {
      return URL(fileURLWithPath: arguments[index + 1])
    }
    return try applicationSupportDirectory()
      .appendingPathComponent("run", isDirectory: true)
      .appendingPathComponent("control.sock")
  }

  private static func databaseURL(arguments: [String]) throws -> URL {
    if let index = arguments.firstIndex(of: "--database"), arguments.indices.contains(index + 1) {
      return URL(fileURLWithPath: arguments[index + 1])
    }
    return try applicationSupportDirectory().appendingPathComponent("micflurry.db")
  }

  private static func applicationSupportDirectory() throws -> URL {
    guard
      let directory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return directory.appendingPathComponent("MicFlurry", isDirectory: true)
  }
}
