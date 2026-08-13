public struct LinearResampler: Sendable {
  public private(set) var inputRate: UInt32
  public private(set) var outputRate: UInt32

  private var previous: Float?
  private var inputPosition: UInt64 = 0
  private var nextOutputPosition = 0.0

  public init(inputRate: UInt32, outputRate: UInt32) {
    precondition(inputRate > 0 && outputRate > 0)
    self.inputRate = inputRate
    self.outputRate = outputRate
  }

  public mutating func reconfigure(inputRate: UInt32, outputRate: UInt32) {
    self = Self(inputRate: inputRate, outputRate: outputRate)
  }

  public mutating func process(_ samples: [Int16]) -> [Float] {
    var output: [Float] = []
    let estimatedCount = samples.count * Int(outputRate) / Int(inputRate) + 2
    output.reserveCapacity(estimatedCount)

    for sample in samples {
      let current = Float(sample) / 32_768
      let currentPosition = Double(inputPosition)
      if let previous {
        let previousPosition = currentPosition - 1
        while nextOutputPosition <= currentPosition {
          let fraction = Float(min(1, max(0, nextOutputPosition - previousPosition)))
          output.append(previous + (current - previous) * fraction)
          nextOutputPosition += Double(inputRate) / Double(outputRate)
        }
      } else {
        output.append(current)
        nextOutputPosition = Double(inputRate) / Double(outputRate)
      }
      previous = current
      inputPosition += 1
    }
    return output
  }
}
