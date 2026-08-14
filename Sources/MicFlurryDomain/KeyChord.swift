import Foundation

/// A modifier role a key plays inside a KeyChord.
public enum KeyChordModifier: String, Equatable, Sendable {
  case fn
  case control
  case option
  case shift
  case command
}

/// One physical key in a KeyChord: its canonical name, ANSI keyCode, and
/// optional modifier role.
public struct KeyChordKey: Equatable, Sendable {
  public var name: String
  public var keyCode: UInt16
  public var modifier: KeyChordModifier?

  public init(name: String, keyCode: UInt16, modifier: KeyChordModifier? = nil) {
    self.name = name
    self.keyCode = keyCode
    self.modifier = modifier
  }
}

/// A set of keys tapped together as one chord, parsed from text such as
/// "fn+control" or "a". Keys go down in listed order and up in reverse order.
public struct KeyChord: Equatable, Sendable {
  public var keys: [KeyChordKey]

  public init(keys: [KeyChordKey]) {
    self.keys = keys
  }

  /// Parses "fn+control" style text. Returns nil when the text is empty or any
  /// token is not a known key name.
  public init?(parsing text: String) {
    var keys: [KeyChordKey] = []
    for token in text.lowercased().split(separator: "+") {
      let name = token.trimmingCharacters(in: .whitespaces)
      guard let key = Self.table[name] else { return nil }
      keys.append(key)
    }
    guard !keys.isEmpty else { return nil }
    self.init(keys: keys)
  }

  /// Canonical text form, e.g. "fn+control".
  public var text: String {
    keys.map(\.name).joined(separator: "+")
  }

  private static let table: [String: KeyChordKey] = {
    var table: [String: KeyChordKey] = [:]
    func add(
      _ name: String, _ keyCode: UInt16, _ modifier: KeyChordModifier? = nil,
      aliases: [String] = []
    ) {
      let key = KeyChordKey(name: name, keyCode: keyCode, modifier: modifier)
      table[name] = key
      for alias in aliases {
        table[alias] = key
      }
    }
    add("fn", 0x3f, .fn)
    add("control", 0x3b, .control, aliases: ["ctrl"])
    add("option", 0x3a, .option, aliases: ["alt"])
    add("shift", 0x38, .shift)
    add("command", 0x37, .command, aliases: ["cmd"])
    let plain: [(String, UInt16)] = [
      ("a", 0x00), ("b", 0x0b), ("c", 0x08), ("d", 0x02), ("e", 0x0e), ("f", 0x03),
      ("g", 0x05), ("h", 0x04), ("i", 0x22), ("j", 0x26), ("k", 0x28), ("l", 0x25),
      ("m", 0x2e), ("n", 0x2d), ("o", 0x1f), ("p", 0x23), ("q", 0x0c), ("r", 0x0f),
      ("s", 0x01), ("t", 0x11), ("u", 0x20), ("v", 0x09), ("w", 0x0d), ("x", 0x07),
      ("y", 0x10), ("z", 0x06),
      ("0", 0x1d), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15),
      ("5", 0x17), ("6", 0x16), ("7", 0x1a), ("8", 0x1c), ("9", 0x19),
      ("space", 0x31), ("return", 0x24), ("tab", 0x30), ("escape", 0x35), ("delete", 0x33),
      ("up", 0x7e), ("down", 0x7d), ("left", 0x7b), ("right", 0x7c),
      ("f1", 0x7a), ("f2", 0x78), ("f3", 0x63), ("f4", 0x76), ("f5", 0x60), ("f6", 0x61),
      ("f7", 0x62), ("f8", 0x64), ("f9", 0x65), ("f10", 0x6d), ("f11", 0x67), ("f12", 0x6f),
    ]
    for (name, keyCode) in plain {
      add(name, keyCode)
    }
    table["enter"] = table["return"]
    table["esc"] = table["escape"]
    return table
  }()
}
