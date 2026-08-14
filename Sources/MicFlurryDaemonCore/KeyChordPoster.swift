import ApplicationServices
import CoreGraphics
import Foundation
import MicFlurryDomain

/// Posts configured key chords as synthetic CGEvents.
///
/// Used for the dictation shortcut around an ATVV audio session and for
/// HID-driven key mappings such as volume keys typing characters.
public protocol KeyChordPosting: Sendable {
  /// Taps the chord: every key down in order, then up in reverse order.
  /// Returns false when the process lacks Accessibility trust, the chord is
  /// empty, or any CGEvent could not be created.
  func postChord(_ chord: KeyChord) -> Bool
  /// Holds the chord down or releases it, without the matching counterpart.
  /// Used for push-to-talk tools that expect a held key for the whole session.
  func holdChord(_ chord: KeyChord, down: Bool) -> Bool
}

public struct CGEventKeyChordPoster: KeyChordPosting {
  public init() {}

  public func postChord(_ chord: KeyChord) -> Bool {
    guard AXIsProcessTrusted(), !chord.keys.isEmpty else { return false }
    var succeeded = holdChord(chord, down: true)
    succeeded = holdChord(chord, down: false) && succeeded
    return succeeded
  }

  public func holdChord(_ chord: KeyChord, down: Bool) -> Bool {
    guard AXIsProcessTrusted(), !chord.keys.isEmpty else { return false }
    guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
    var flags = CGEventFlags()
    var succeeded = true
    if down {
      for key in chord.keys {
        flags.formUnion(Self.flags(for: key.modifier))
        succeeded = post(key.keyCode, keyDown: true, flags: flags, source: source) && succeeded
      }
    } else {
      flags = chord.keys.reduce(into: CGEventFlags()) { $0.formUnion(Self.flags(for: $1.modifier)) }
      for key in chord.keys.reversed() {
        flags.subtract(Self.flags(for: key.modifier))
        succeeded = post(key.keyCode, keyDown: false, flags: flags, source: source) && succeeded
      }
    }
    return succeeded
  }

  private static func flags(for modifier: KeyChordModifier?) -> CGEventFlags {
    switch modifier {
    case .fn: .maskSecondaryFn
    case .control: .maskControl
    case .option: .maskAlternate
    case .shift: .maskShift
    case .command: .maskCommand
    case .none: []
    }
  }

  private func post(
    _ keyCode: UInt16, keyDown: Bool, flags: CGEventFlags, source: CGEventSource
  ) -> Bool {
    guard
      let event = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
    else { return false }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    return true
  }
}
