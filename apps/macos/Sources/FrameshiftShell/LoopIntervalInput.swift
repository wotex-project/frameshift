import Foundation

public enum LoopIntervalInput {
  public enum Unit: String, CaseIterable, Codable, Sendable {
    case milliseconds, seconds, minutes, hours

    public var multiplier: Int {
      switch self {
      case .milliseconds: 1
      case .seconds: 1_000
      case .minutes: 60_000
      case .hours: 3_600_000
      }
    }
  }

  public static let maximumMilliseconds = 31_536_000_000
  public static let maximumMinutes = 525_600

  public static func minimumMinutes(minimumDwellMs: Int?) -> Int {
    let minimum = max(1, minimumDwellMs ?? 1)
    return (minimum - 1) / 60_000 + 1
  }

  public static func dwellMilliseconds(_ input: String, minimumDwellMs: Int?) -> Int? {
    dwellMilliseconds(input, unit: .minutes, minimumDwellMs: minimumDwellMs)
  }

  public static func dwellMilliseconds(_ input: String, unit: Unit, minimumDwellMs: Int?) -> Int? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int(trimmed), value > 0 else { return nil }
    let (milliseconds, overflow) = value.multipliedReportingOverflow(by: unit.multiplier)
    guard !overflow, milliseconds >= max(1, minimumDwellMs ?? 1),
      milliseconds <= maximumMilliseconds
    else { return nil }

    return milliseconds
  }

  public static func exactUnit(for milliseconds: Int) -> Unit {
    for unit in [Unit.hours, .minutes, .seconds] where milliseconds % unit.multiplier == 0 {
      return unit
    }
    return .milliseconds
  }
}
