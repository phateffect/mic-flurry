@preconcurrency import Darwin
@preconcurrency import Dispatch
import Foundation
import MicFlurryDomain

@MainActor
public final class UnixControlServer {
  public let socketURL: URL

  private let service: any ControlService
  private var listenerDescriptor: Int32 = -1
  private var listenerSource: (any DispatchSourceRead)?
  private var clients: [Int32: SocketClient] = [:]
  private var eventTask: Task<Void, Never>?

  public init(socketURL: URL, service: any ControlService) {
    self.socketURL = socketURL
    self.service = service
  }

  deinit {
    if listenerDescriptor >= 0 { Darwin.close(listenerDescriptor) }
  }

  public func start() throws {
    guard listenerDescriptor < 0 else { return }
    try prepareDirectory()
    try removeStaleSocket()

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw socketError("create Unix socket") }
    do {
      var noSignal: Int32 = 1
      guard
        setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          &noSignal,
          socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0
      else { throw socketError("configure Unix socket") }

      var address = try socketAddress()
      let length = socklen_t(address.sun_len)
      let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(descriptor, $0, length)
        }
      }
      guard bindResult == 0 else { throw socketError("bind Unix socket") }
      guard chmod(socketURL.path, 0o600) == 0 else {
        throw socketError("protect Unix socket")
      }
      guard Darwin.listen(descriptor, 16) == 0 else { throw socketError("listen on Unix socket") }
      guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
        throw socketError("make Unix socket nonblocking")
      }

      listenerDescriptor = descriptor
      let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.acceptPendingClients() }
      }
      source.setCancelHandler { Darwin.close(descriptor) }
      listenerSource = source
      source.resume()

      let events = service.events
      eventTask = Task { [weak self] in
        for await event in events {
          guard let self else { return }
          self.broadcast(event)
        }
      }
    } catch {
      Darwin.close(descriptor)
      try? FileManager.default.removeItem(at: socketURL)
      throw error
    }
  }

  public func stop() {
    eventTask?.cancel()
    eventTask = nil
    let activeClients = Array(clients.values)
    clients.removeAll()
    for client in activeClients { client.stop() }
    listenerDescriptor = -1
    listenerSource?.cancel()
    listenerSource = nil
    try? FileManager.default.removeItem(at: socketURL)
  }

  private func prepareDirectory() throws {
    let directory = socketURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    var information = stat()
    guard lstat(directory.path, &information) == 0 else {
      throw socketError("inspect control directory")
    }
    guard information.st_uid == getuid(), information.st_mode & S_IFMT == S_IFDIR else {
      throw ControlProtocolError.socket("control directory is not owned by the current user")
    }
    guard chmod(directory.path, 0o700) == 0 else {
      throw socketError("protect control directory")
    }
  }

  private func removeStaleSocket() throws {
    var information = stat()
    guard lstat(socketURL.path, &information) == 0 else {
      if errno == ENOENT { return }
      throw socketError("inspect existing socket")
    }
    guard information.st_uid == getuid(), information.st_mode & S_IFMT == S_IFSOCK else {
      throw ControlProtocolError.socket("refusing to replace a non-socket or foreign-owned path")
    }
    guard unlink(socketURL.path) == 0 else { throw socketError("remove stale Unix socket") }
  }

  private func socketAddress() throws -> sockaddr_un {
    let bytes = Array(socketURL.path.utf8)
    var address = sockaddr_un()
    let headerSize = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) ?? 2
    guard bytes.count + 1 <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw ControlProtocolError.socket("Unix socket path is too long")
    }
    let length = headerSize + bytes.count + 1
    guard length <= Int(UInt8.max) else {
      throw ControlProtocolError.socket("Unix socket address is too long")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(length)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: bytes)
      destination[bytes.count] = 0
    }
    return address
  }

  private func acceptPendingClients() {
    while true {
      let descriptor = Darwin.accept(listenerDescriptor, nil, nil)
      if descriptor < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        return
      }
      guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
        Darwin.close(descriptor)
        continue
      }
      var noSignal: Int32 = 1
      guard
        setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          &noSignal,
          socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0
      else {
        Darwin.close(descriptor)
        continue
      }
      let client = SocketClient(descriptor: descriptor) { [weak self] descriptor, frame in
        self?.handle(frame, from: descriptor)
      } onClose: { [weak self] descriptor in
        self?.clients.removeValue(forKey: descriptor)
      }
      clients[descriptor] = client
      client.start()
    }
  }

  private func handle(_ frame: Data, from descriptor: Int32) {
    let request: JSONRPCRequest
    do {
      request = try JSONRPCCodec.decoder().decode(JSONRPCRequest.self, from: frame)
    } catch {
      send(
        JSONRPCResponse(
          id: .null,
          error: JSONRPCError(code: -32_700, message: "parse error")
        ),
        to: descriptor
      )
      return
    }
    Task { [weak self] in
      guard let self,
        let response = await ControlRouter.route(request, to: self.service)
      else { return }
      self.send(response, to: descriptor)
    }
  }

  private func send<T: Encodable>(_ value: T, to descriptor: Int32) {
    do {
      guard let client = clients[descriptor] else { return }
      try client.send(JSONRPCCodec.line(value))
    } catch {
      clients[descriptor]?.stop()
      clients.removeValue(forKey: descriptor)
    }
  }

  private func broadcast(_ event: Event) {
    do {
      let notification = JSONRPCNotification(
        method: ControlMethods.event,
        params: try JSONRPCCodec.eventValue(event)
      )
      let line = try JSONRPCCodec.line(notification)
      var failedClients: [SocketClient] = []
      for (_, client) in clients {
        do {
          try client.send(line)
        } catch {
          failedClients.append(client)
        }
      }
      for client in failedClients {
        client.stop()
      }
    } catch {
      // An oversized or unencodable event is dropped without affecting daemon work.
    }
  }

  private func socketError(_ operation: String) -> ControlProtocolError {
    ControlProtocolError.socket("\(operation): \(String(cString: strerror(errno)))")
  }
}

@MainActor
private final class SocketClient {
  let descriptor: Int32

  private var source: (any DispatchSourceRead)?
  private var writeSource: (any DispatchSourceWrite)?
  private var buffer = Data()
  private var output = Data()
  private var outputOffset = 0
  private let onFrame: @MainActor (Int32, Data) -> Void
  private let onClose: @MainActor (Int32) -> Void
  private var stopped = false

  init(
    descriptor: Int32,
    onFrame: @escaping @MainActor (Int32, Data) -> Void,
    onClose: @escaping @MainActor (Int32) -> Void
  ) {
    self.descriptor = descriptor
    self.onFrame = onFrame
    self.onClose = onClose
  }

  func start() {
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.readAvailableBytes() }
    }
    source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
    self.source = source
    source.resume()
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    source?.cancel()
    source = nil
    writeSource?.cancel()
    writeSource = nil
    onClose(descriptor)
  }

  func send(_ data: Data) throws {
    let pendingBytes = output.count - outputOffset
    guard pendingBytes + data.count <= 256 * 1_024 else {
      throw ControlProtocolError.socket("client cannot keep up with control events")
    }
    if outputOffset > 0 {
      output.removeFirst(outputOffset)
      outputOffset = 0
    }
    output.append(data)
    try flushOutput()
  }

  private func readAvailableBytes() {
    var chunk = [UInt8](repeating: 0, count: 8_192)
    while true {
      let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
      if count > 0 {
        buffer.append(contentsOf: chunk.prefix(count))
        guard buffer.count <= JSONRPCCodec.maximumFrameBytes else {
          stop()
          return
        }
        extractFrames()
      } else if count == 0 {
        stop()
        return
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        return
      } else {
        stop()
        return
      }
    }
  }

  private func extractFrames() {
    while let newline = buffer.firstIndex(of: 0x0a) {
      let frame = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if !frame.isEmpty { onFrame(descriptor, frame) }
    }
  }

  private func flushOutput() throws {
    while outputOffset < output.count {
      let written = output.withUnsafeBytes { bytes in
        Darwin.send(
          descriptor,
          bytes.baseAddress?.advanced(by: outputOffset),
          bytes.count - outputOffset,
          0
        )
      }
      if written > 0 {
        outputOffset += written
      } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        ensureWriteSource()
        return
      } else {
        throw ControlProtocolError.socket("write to control client failed")
      }
    }
    output.removeAll(keepingCapacity: true)
    outputOffset = 0
    writeSource?.cancel()
    writeSource = nil
  }

  private func ensureWriteSource() {
    guard writeSource == nil else { return }
    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        do {
          try self.flushOutput()
        } catch {
          self.stop()
        }
      }
    }
    writeSource = source
    source.resume()
  }
}
