import Synchronization

/// A bounded, preallocated single-producer/single-consumer Float32 ring buffer.
///
/// The producer alone calls `write`; the AudioUnit render thread alone calls `read`.
/// Reading never allocates, blocks, logs, or takes a lock. Samples that do not fit are dropped.
public final class SPSCRingBuffer: @unchecked Sendable {
  public let capacity: Int

  private let storage: UnsafeMutablePointer<Float>
  private let readPosition = Atomic<UInt64>(0)
  private let writePosition = Atomic<UInt64>(0)
  private let droppedPosition = Atomic<UInt64>(0)

  public init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
    storage = .allocate(capacity: capacity)
    storage.initialize(repeating: 0, count: capacity)
  }

  deinit {
    storage.deinitialize(count: capacity)
    storage.deallocate()
  }

  public var availableSamples: Int {
    let read = readPosition.load(ordering: .acquiring)
    let written = writePosition.load(ordering: .acquiring)
    return min(capacity, Int(written &- read))
  }

  public var droppedSamples: UInt64 {
    droppedPosition.load(ordering: .relaxed)
  }

  /// Writes as many samples as fit and returns the number accepted.
  @discardableResult
  public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
    let read = readPosition.load(ordering: .acquiring)
    let written = writePosition.load(ordering: .relaxed)
    let used = min(capacity, Int(written &- read))
    let accepted = min(samples.count, capacity - used)

    for offset in 0..<accepted {
      storage[Int((written + UInt64(offset)) % UInt64(capacity))] = samples[offset]
    }
    writePosition.store(written + UInt64(accepted), ordering: .releasing)

    let dropped = samples.count - accepted
    if dropped > 0 {
      let previous = droppedPosition.load(ordering: .relaxed)
      droppedPosition.store(previous + UInt64(dropped), ordering: .relaxed)
    }
    return accepted
  }

  /// Reads available samples and fills the remainder with silence. Returns the number consumed.
  @discardableResult
  public func read(into output: UnsafeMutableBufferPointer<Float>) -> Int {
    let read = readPosition.load(ordering: .relaxed)
    let written = writePosition.load(ordering: .acquiring)
    let consumed = min(output.count, Int(written &- read))

    for offset in 0..<consumed {
      output[offset] = storage[Int((read + UInt64(offset)) % UInt64(capacity))]
    }
    if consumed < output.count {
      for offset in consumed..<output.count {
        output[offset] = 0
      }
    }
    readPosition.store(read + UInt64(consumed), ordering: .releasing)
    return consumed
  }
}
