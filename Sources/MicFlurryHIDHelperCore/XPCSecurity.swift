import Foundation

public struct HIDHelperSecurityPolicy: Equatable, Sendable {
  public static let daemonIdentifier = "io.phateffect.MicFlurry.daemon"
  public static let helperIdentifier = "io.phateffect.MicFlurry.hid-helper"

  public let daemonCodeSigningRequirement: String

  public init(teamID: String) throws {
    guard Self.validTeamID(teamID) else { throw HIDHelperSecurityError.invalidTeamID }
    daemonCodeSigningRequirement =
      "anchor apple generic and identifier \"\(Self.daemonIdentifier)\""
      + " and certificate leaf[subject.OU] = \"\(teamID)\""
  }

  #if DEBUG
    public static var developmentAdHoc: HIDHelperSecurityPolicy {
      HIDHelperSecurityPolicy(
        uncheckedRequirement: "identifier \"\(daemonIdentifier)\""
      )
    }
  #endif

  #if MICFLURRY_PRIVATE_DISTRIBUTION
    public static func privateAdHoc(daemonCDHash: String) throws -> HIDHelperSecurityPolicy {
      guard validCDHash(daemonCDHash) else { throw HIDHelperSecurityError.invalidCDHash }
      return HIDHelperSecurityPolicy(
        uncheckedRequirement:
          "identifier \"\(daemonIdentifier)\" and cdhash H\"\(daemonCDHash)\""
      )
    }
  #endif

  public func accepts(effectiveUID: uid_t, consoleUID: uid_t?) -> Bool {
    effectiveUID != 0 && consoleUID == effectiveUID
  }

  private init(uncheckedRequirement: String) {
    daemonCodeSigningRequirement = uncheckedRequirement
  }

  private static func validTeamID(_ value: String) -> Bool {
    value.count == 10
      && value.allSatisfy { character in
        character.isASCII && (character.isUppercase || character.isNumber)
      }
  }

  private static func validCDHash(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy { $0.isHexDigit }
  }
}

public enum HIDHelperSecurityError: Error, Equatable, Sendable {
  case invalidTeamID
  case invalidCDHash
  case missingProductionTeamID
  case notRoot
  case noConsoleUser
}
