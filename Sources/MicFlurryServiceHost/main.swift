import Foundation
import ServiceManagement

@main
enum MicFlurryServiceHostMain {
  private static let agentPlist = "io.phateffect.MicFlurry.daemon.plist"
  private static let daemonPlist = "io.phateffect.MicFlurry.hid-helper.plist"

  static func main() {
    do {
      let command = CommandLine.arguments.dropFirst().first ?? "status"
      let agent = SMAppService.agent(plistName: agentPlist)
      let daemon = SMAppService.daemon(plistName: daemonPlist)
      switch command {
      case "status":
        printStatuses(agent: agent, daemon: daemon)
      case "register":
        guard Bundle.main.object(forInfoDictionaryKey: "MicFlurryPrivateDistribution") == nil else {
          throw HostError.privateDistributionUsesLegacyServices
        }
        try requireInstalledApplication()
        try register(agent, name: "agent")
        try register(daemon, name: "hid-helper")
        printStatuses(agent: agent, daemon: daemon)
        if daemon.status == .requiresApproval {
          FileHandle.standardError.write(
            Data(
              "MicFlurry HID helper requires administrator approval in System Settings.\n".utf8
            )
          )
        }
      case "unregister":
        try unregister(daemon)
        try unregister(agent)
        printStatuses(agent: agent, daemon: daemon)
      case "open-settings":
        SMAppService.openSystemSettingsLoginItems()
      default:
        throw HostError.usage
      }
    } catch {
      FileHandle.standardError.write(Data("MicFlurry service host: \(error)\n".utf8))
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func register(_ service: SMAppService, name: String) throws {
    switch service.status {
    case .enabled:
      return
    case .requiresApproval:
      FileHandle.standardError.write(Data("\(name) requires approval\n".utf8))
    case .notRegistered, .notFound:
      try service.register()
    @unknown default:
      throw HostError.unknownServiceStatus
    }
  }

  private static func unregister(_ service: SMAppService) throws {
    switch service.status {
    case .notRegistered, .notFound:
      return
    case .enabled, .requiresApproval:
      try service.unregister()
    @unknown default:
      throw HostError.unknownServiceStatus
    }
  }

  private static func printStatuses(agent: SMAppService, daemon: SMAppService) {
    print("agent=\(description(agent.status))")
    print("hid-helper=\(description(daemon.status))")
  }

  private static func description(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "not_registered"
    case .enabled: "enabled"
    case .requiresApproval: "requires_approval"
    case .notFound: "not_found"
    @unknown default: "unknown"
    }
  }

  private static func requireInstalledApplication() throws {
    guard Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/MicFlurry.app" else {
      throw HostError.mustBeInstalledInApplications
    }
  }
}

private enum HostError: Error, CustomStringConvertible {
  case mustBeInstalledInApplications
  case privateDistributionUsesLegacyServices
  case unknownServiceStatus
  case usage

  var description: String {
    switch self {
    case .mustBeInstalledInApplications:
      "registration requires /Applications/MicFlurry.app"
    case .privateDistributionUsesLegacyServices:
      "private builds use the bundled traditional LaunchAgent/LaunchDaemon installer"
    case .unknownServiceStatus:
      "ServiceManagement returned an unknown status"
    case .usage:
      "usage: MicFlurry [status|register|unregister|open-settings]"
    }
  }
}
