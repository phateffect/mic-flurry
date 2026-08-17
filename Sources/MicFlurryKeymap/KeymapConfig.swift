import Foundation
import MicFlurryDomain

public struct KeymapOptions: Equatable, Sendable {
  public var doubleClickMilliseconds: UInt64
  public var holdMilliseconds: UInt64
  public var sequenceIntervalMilliseconds: UInt64

  public init(
    doubleClickMilliseconds: UInt64 = 300,
    holdMilliseconds: UInt64 = 600,
    sequenceIntervalMilliseconds: UInt64 = 50
  ) {
    self.doubleClickMilliseconds = doubleClickMilliseconds
    self.holdMilliseconds = holdMilliseconds
    self.sequenceIntervalMilliseconds = sequenceIntervalMilliseconds
  }
}

public enum KeymapOutput: Equatable, Sendable {
  case noop
  case chords([KeyChord])
}

public struct KeymapBinding: Equatable, Sendable {
  public var click: KeymapOutput?
  public var doubleClick: KeymapOutput?
  public var hold: KeymapOutput?

  public init(
    click: KeymapOutput? = nil,
    doubleClick: KeymapOutput? = nil,
    hold: KeymapOutput? = nil
  ) {
    self.click = click
    self.doubleClick = doubleClick
    self.hold = hold
  }
}

public struct KeymapConfiguration: Equatable, Sendable {
  public static let schemaVersion = 1
  public static let supportedActions: Set<KeyboardAction> = [
    .up, .down, .left, .right, .select, .back, .home, .playPause, .previous, .next,
    .volumeDown, .volumeUp, .mute, .power, .microphone, .menu, .tv,
  ]

  public static func availableActions(model: String) -> [KeyboardAction] {
    RemoteCatalog.keymapActions(model: model) ?? []
  }

  public static func availableActionSet(model: String) -> Set<KeyboardAction> {
    Set(availableActions(model: model))
  }

  public static func discoverableDefaultBindings(model: String) -> [KeyboardAction: KeymapBinding] {
    var bindings = Dictionary(
      uniqueKeysWithValues: availableActions(model: model).map { action in
        (action, KeymapBinding(click: .noop))
      }
    )
    bindings[.up] = KeymapBinding(click: .chords([KeyChord(parsing: "up")!]))
    bindings[.down] = KeymapBinding(click: .chords([KeyChord(parsing: "down")!]))
    bindings[.left] = KeymapBinding(click: .chords([KeyChord(parsing: "left")!]))
    bindings[.right] = KeymapBinding(click: .chords([KeyChord(parsing: "right")!]))
    bindings[.select] = KeymapBinding(click: .chords([KeyChord(parsing: "return")!]))
    bindings[.back] = KeymapBinding(click: .chords([KeyChord(parsing: "escape")!]))
    return bindings
  }

  public var model: String
  public var options: KeymapOptions
  public var bindings: [KeyboardAction: KeymapBinding]

  public init(
    model: String,
    options: KeymapOptions = KeymapOptions(),
    bindings: [KeyboardAction: KeymapBinding] = [:]
  ) {
    self.model = model
    self.options = options
    self.bindings = bindings
  }
}

public enum KeymapConfigError: Error, Equatable, Sendable, CustomStringConvertible {
  case fileTooLarge(Int)
  case notRegularFile
  case wrongOwner
  case syntax(line: Int, message: String)
  case missingField(String)
  case duplicateField(String)
  case unknownField(String)
  case invalidInteger(String)
  case outOfRange(String)
  case invalidModel(expected: String, actual: String)
  case invalidAction(String)
  case invalidOutput(String)
  case invalidChord(String)

  public var description: String {
    switch self {
    case .fileTooLarge(let size): "keymap file is too large: \(size) bytes"
    case .notRegularFile: "keymap path is not a regular file"
    case .wrongOwner: "keymap file is not owned by the current user"
    case .syntax(let line, let message): "keymap TOML line \(line): \(message)"
    case .missingField(let field): "missing keymap field: \(field)"
    case .duplicateField(let field): "duplicate keymap field: \(field)"
    case .unknownField(let field): "unknown keymap field: \(field)"
    case .invalidInteger(let field): "invalid keymap integer: \(field)"
    case .outOfRange(let field): "keymap value out of range: \(field)"
    case .invalidModel(let expected, let actual):
      "keymap model mismatch: expected \(expected), got \(actual)"
    case .invalidAction(let action): "unknown keymap action: \(action)"
    case .invalidOutput(let output): "invalid keymap output: \(output)"
    case .invalidChord(let chord): "invalid key chord: \(chord)"
    }
  }
}

public enum KeymapTOML {
  public static func parse(_ text: String, expectedModel: String) throws -> KeymapConfiguration {
    var parser = Parser(expectedModel: expectedModel)
    for (offset, rawLine) in text.split(
      omittingEmptySubsequences: false,
      whereSeparator: \.isNewline
    ).enumerated() {
      try parser.consume(line: String(rawLine), number: offset + 1)
    }
    return try parser.finish()
  }

  public static func serialize(_ configuration: KeymapConfiguration) -> String {
    var lines = [
      "schema_version = \(KeymapConfiguration.schemaVersion)",
      "model = \(quoted(configuration.model))",
      "",
      "[options]",
      "double_click_ms = \(configuration.options.doubleClickMilliseconds)",
      "hold_ms = \(configuration.options.holdMilliseconds)",
      "sequence_interval_ms = \(configuration.options.sequenceIntervalMilliseconds)",
    ]
    let preferredActions = KeymapConfiguration.availableActions(model: configuration.model)
    let preferredSet = Set(preferredActions)
    let actions =
      preferredActions.filter { configuration.bindings[$0] != nil }
      + configuration.bindings.keys.filter { !preferredSet.contains($0) }.sorted {
        $0.rawValue < $1.rawValue
      }
    let simple = actions.filter {
      let binding = configuration.bindings[$0]!
      return binding.doubleClick == nil && binding.hold == nil && binding.click != nil
    }
    if !simple.isEmpty {
      lines += ["", "[keymap]"]
      for action in simple {
        lines.append("\(action.rawValue) = \(format(configuration.bindings[action]!.click!))")
      }
    }
    for action in actions where !simple.contains(action) {
      guard let binding = configuration.bindings[action] else { continue }
      lines += ["", "[keymap.\(action.rawValue)]"]
      if let output = binding.click { lines.append("click = \(format(output))") }
      if let output = binding.doubleClick { lines.append("double_click = \(format(output))") }
      if let output = binding.hold { lines.append("hold = \(format(output))") }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func quoted(_ value: String) -> String {
    let data = try! JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
  }

  private static func format(_ output: KeymapOutput) -> String {
    switch output {
    case .noop: return quoted("noop")
    case .chords(let chords) where chords.count == 1: return quoted(chords[0].text)
    case .chords(let chords): return "[\(chords.map { quoted($0.text) }.joined(separator: ", "))]"
    }
  }
}

public final class KeymapFileStore {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public func fileURL(model: String) -> URL {
    directory.appendingPathComponent("\(model).toml", isDirectory: false)
  }

  public func loadOrMigrate(
    model: String,
    legacyActionChords: [String: String]
  ) throws -> KeymapConfiguration {
    let fileManager = FileManager.default
    let url = fileURL(model: model)
    if fileManager.fileExists(atPath: url.path) { return try load(model: model) }
    let availableActions = KeymapConfiguration.availableActionSet(model: model)
    var bindings = KeymapConfiguration.discoverableDefaultBindings(model: model)
    for (name, chordText) in legacyActionChords {
      guard let action = KeyboardAction(rawValue: name),
        availableActions.contains(action),
        let chord = KeyChord(parsing: chordText)
      else { continue }
      bindings[action] = KeymapBinding(click: .chords([chord]))
    }
    let configuration = KeymapConfiguration(model: model, bindings: bindings)
    try write(configuration)
    return configuration
  }

  public func load(model: String) throws -> KeymapConfiguration {
    let fileManager = FileManager.default
    let url = fileURL(model: model)
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw KeymapConfigError.notRegularFile
    }
    if let owner = attributes[.ownerAccountID] as? NSNumber,
      owner.uint32Value != getuid()
    {
      throw KeymapConfigError.wrongOwner
    }
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard size <= 65_536 else { throw KeymapConfigError.fileTooLarge(size) }
    return try KeymapTOML.parse(String(contentsOf: url, encoding: .utf8), expectedModel: model)
  }

  public func write(_ configuration: KeymapConfiguration) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let destination = fileURL(model: configuration.model)
    let temporary = directory.appendingPathComponent(
      ".\(configuration.model).\(UUID().uuidString).tmp",
      isDirectory: false
    )
    do {
      try Data(KeymapTOML.serialize(configuration).utf8).write(
        to: temporary,
        options: .withoutOverwriting
      )
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
      if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try fileManager.moveItem(at: temporary, to: destination)
      }
    } catch {
      try? fileManager.removeItem(at: temporary)
      throw error
    }
  }
}

private struct Parser {
  enum Section: Equatable {
    case root
    case options
    case keymap
    case binding(KeyboardAction)
  }

  let expectedModel: String
  var availableActions: Set<KeyboardAction> {
    KeymapConfiguration.availableActionSet(model: expectedModel)
  }
  var section: Section = .root
  var seen: Set<String> = []
  var schemaVersion: Int?
  var model: String?
  var options = KeymapOptions()
  var bindings: [KeyboardAction: KeymapBinding] = [:]

  mutating func consume(line rawLine: String, number: Int) throws {
    let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty else { return }
    if line.hasPrefix("[") {
      guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
        throw KeymapConfigError.syntax(line: number, message: "invalid section")
      }
      let name = String(line.dropFirst().dropLast())
      switch name {
      case "options": section = .options
      case "keymap": section = .keymap
      default:
        guard name.hasPrefix("keymap."),
          let action = KeyboardAction(rawValue: String(name.dropFirst("keymap.".count))),
          availableActions.contains(action)
        else { throw KeymapConfigError.unknownField(name) }
        section = .binding(action)
      }
      return
    }
    guard let equals = firstUnquotedEquals(line) else {
      throw KeymapConfigError.syntax(line: number, message: "expected key = value")
    }
    let key = line[..<equals].trimmingCharacters(in: .whitespaces)
    let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty, !value.isEmpty else {
      throw KeymapConfigError.syntax(line: number, message: "empty key or value")
    }
    try assign(key: key, value: value)
  }

  mutating func finish() throws -> KeymapConfiguration {
    guard schemaVersion != nil else { throw KeymapConfigError.missingField("schema_version") }
    guard schemaVersion == KeymapConfiguration.schemaVersion else {
      throw KeymapConfigError.outOfRange("schema_version")
    }
    guard let model else { throw KeymapConfigError.missingField("model") }
    guard model == expectedModel else {
      throw KeymapConfigError.invalidModel(expected: expectedModel, actual: model)
    }
    guard (100...1000).contains(options.doubleClickMilliseconds) else {
      throw KeymapConfigError.outOfRange("options.double_click_ms")
    }
    guard (250...3000).contains(options.holdMilliseconds) else {
      throw KeymapConfigError.outOfRange("options.hold_ms")
    }
    guard (0...1000).contains(options.sequenceIntervalMilliseconds) else {
      throw KeymapConfigError.outOfRange("options.sequence_interval_ms")
    }
    return KeymapConfiguration(model: model, options: options, bindings: bindings)
  }

  mutating func assign(key: String, value: String) throws {
    let path: String
    switch section {
    case .root:
      path = key
      try mark(path)
      switch key {
      case "schema_version": schemaVersion = try integer(value, field: path)
      case "model": model = try string(value, field: path)
      default: throw KeymapConfigError.unknownField(path)
      }
    case .options:
      path = "options.\(key)"
      try mark(path)
      let integer = try integer(value, field: path)
      guard integer >= 0 else { throw KeymapConfigError.outOfRange(path) }
      let parsed = UInt64(integer)
      switch key {
      case "double_click_ms": options.doubleClickMilliseconds = parsed
      case "hold_ms": options.holdMilliseconds = parsed
      case "sequence_interval_ms": options.sequenceIntervalMilliseconds = parsed
      default: throw KeymapConfigError.unknownField(path)
      }
    case .keymap:
      guard let action = KeyboardAction(rawValue: key),
        availableActions.contains(action)
      else {
        throw KeymapConfigError.invalidAction(key)
      }
      path = "keymap.\(key)"
      try mark(path)
      guard bindings[action] == nil else { throw KeymapConfigError.duplicateField(path) }
      bindings[action] = KeymapBinding(click: try output(value))
    case .binding(let action):
      path = "keymap.\(action.rawValue).\(key)"
      try mark(path)
      var binding = bindings[action] ?? KeymapBinding()
      switch key {
      case "click": binding.click = try output(value)
      case "double_click": binding.doubleClick = try output(value)
      case "hold": binding.hold = try output(value)
      default: throw KeymapConfigError.unknownField(path)
      }
      bindings[action] = binding
    }
  }

  mutating func mark(_ path: String) throws {
    guard seen.insert(path).inserted else { throw KeymapConfigError.duplicateField(path) }
  }

  func integer(_ token: String, field: String) throws -> Int {
    let normalized = token.replacingOccurrences(of: "_", with: "")
    guard let value = Int(normalized) else { throw KeymapConfigError.invalidInteger(field) }
    return value
  }

  func string(_ token: String, field: String) throws -> String {
    guard token.hasPrefix("\""), token.hasSuffix("\"") else {
      throw KeymapConfigError.invalidOutput(field)
    }
    do { return try JSONDecoder().decode(String.self, from: Data(token.utf8)) } catch {
      throw KeymapConfigError.invalidOutput(field)
    }
  }

  func output(_ token: String) throws -> KeymapOutput {
    if token.hasPrefix("[") {
      guard token.hasSuffix("]") else { throw KeymapConfigError.invalidOutput(token) }
      let body = token.dropFirst().dropLast()
      let items = try splitArray(String(body)).map { try string($0, field: "sequence") }
      guard (1...16).contains(items.count), !items.contains("noop") else {
        throw KeymapConfigError.invalidOutput(token)
      }
      return .chords(try items.map(chord))
    }
    let value = try string(token, field: "output")
    if value == "noop" { return .noop }
    return .chords([try chord(value)])
  }

  func chord(_ text: String) throws -> KeyChord {
    guard let chord = KeyChord(parsing: text) else { throw KeymapConfigError.invalidChord(text) }
    return chord
  }
}

private func stripComment(_ line: String) -> String {
  var quoted = false
  var escaped = false
  for index in line.indices {
    let character = line[index]
    if quoted && character == "\\" && !escaped {
      escaped = true
      continue
    }
    if character == "\"" && !escaped { quoted.toggle() }
    if character == "#" && !quoted { return String(line[..<index]) }
    escaped = false
  }
  return line
}

private func firstUnquotedEquals(_ line: String) -> String.Index? {
  var quoted = false
  var escaped = false
  for index in line.indices {
    let character = line[index]
    if quoted && character == "\\" && !escaped {
      escaped = true
      continue
    }
    if character == "\"" && !escaped { quoted.toggle() }
    if character == "=" && !quoted { return index }
    escaped = false
  }
  return nil
}

private func splitArray(_ body: String) throws -> [String] {
  var result: [String] = []
  var start = body.startIndex
  var quoted = false
  var escaped = false
  for index in body.indices {
    let character = body[index]
    if quoted && character == "\\" && !escaped {
      escaped = true
      continue
    }
    if character == "\"" && !escaped { quoted.toggle() }
    if character == "," && !quoted {
      result.append(body[start..<index].trimmingCharacters(in: .whitespaces))
      start = body.index(after: index)
    }
    escaped = false
  }
  guard !quoted else { throw KeymapConfigError.invalidOutput(body) }
  result.append(body[start...].trimmingCharacters(in: .whitespaces))
  return result
}
