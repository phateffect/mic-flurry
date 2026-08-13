import Foundation

public enum AudioProcessing {
  public static func applyGain(_ samples: inout [Float], decibels: Float) {
    let multiplier = pow(10, decibels / 20)
    for index in samples.indices {
      samples[index] = min(1, max(-1, samples[index] * multiplier))
    }
  }

  public static func peakLevelDBFS(_ samples: [Float], floor: Float = -96) -> Float {
    let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
    guard peak > 0 else { return floor }
    return max(floor, 20 * log10(peak))
  }
}
