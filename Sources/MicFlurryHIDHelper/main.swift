import Foundation
import MicFlurryHIDHelperCore

@main
@MainActor
enum MicFlurryHIDHelperMain {
  static func main() {
    do {
      let policy: HIDHelperSecurityPolicy
      if let teamID = Bundle.main.object(forInfoDictionaryKey: "MicFlurryTeamIdentifier") as? String
      {
        policy = try HIDHelperSecurityPolicy(teamID: teamID)
      } else {
        #if MICFLURRY_PRIVATE_DISTRIBUTION
          guard
            let daemonCDHash = Bundle.main.object(
              forInfoDictionaryKey: "MicFlurryDaemonCDHash"
            ) as? String
          else { throw HIDHelperSecurityError.invalidCDHash }
          policy = try .privateAdHoc(daemonCDHash: daemonCDHash)
        #elseif DEBUG
          guard ProcessInfo.processInfo.environment["MICFLURRY_ALLOW_ADHOC_XPC"] == "1" else {
            throw HIDHelperSecurityError.missingProductionTeamID
          }
          policy = .developmentAdHoc
        #else
          throw HIDHelperSecurityError.missingProductionTeamID
        #endif
      }
      let server = try HIDHelperXPCServer(securityPolicy: policy)
      try server.run()
    } catch {
      FileHandle.standardError.write(Data("micflurry-hid-helper: \(error)\n".utf8))
      Foundation.exit(EXIT_FAILURE)
    }
  }
}
