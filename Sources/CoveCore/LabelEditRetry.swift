import Foundation

/// What a failed Gmail request means for the user's change, independent of platform. A network-class
/// failure or a rate limit says nothing about the request itself, so a queued change waits and tries
/// again; a definitive answer settles it.
public enum GmailFailureKind: Equatable, Sendable {
  /// No usable connection (URLError codes below, also found through underlying errors).
  case network
  /// 429, or 403 with a quota reason: Gmail didn't process the request.
  case rateLimited
  /// 404: the email no longer exists.
  case gone
  /// 401: the access token is stale; refresh once, then the sign-in needs renewing.
  case unauthorized
  /// Any other 4xx: Gmail refused the change.
  case refused
  /// 5xx: unknown whether a write was applied, so a write is never retried automatically.
  case server
  /// Anything else (decoding, local errors).
  case other

  /// Only these keep a queued change for a later attempt.
  public var keepsQueued: Bool { self == .network || self == .rateLimited }

  public static let networkCodes: [URLError.Code] = [
    .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    .networkConnectionLost, .timedOut, .dataNotAllowed, .internationalRoamingOff,
  ]

  public static func classify(_ error: Error) -> GmailFailureKind {
    if let failure = error as? HTTPFailure {
      if failure.isRateLimited { return .rateLimited }
      switch failure.statusCode {
      case 404: return .gone
      case 401: return .unauthorized
      case 400..<500: return .refused
      case 500..<600: return .server
      default: return .other
      }
    }
    var current = error as NSError
    for _ in 0..<5 {
      if current.domain == NSURLErrorDomain {
        return networkCodes.contains(URLError.Code(rawValue: current.code)) ? .network : .other
      }
      guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return .other }
      current = underlying
    }
    return .other
  }
}

/// A label change on its way to Gmail: what to add and remove, cumulative over every change to the
/// same email since Gmail last confirmed one. Persisted so a change made offline survives a relaunch.
public struct PendingLabelEdit: Codable, Hashable, Sendable {
  public var add: Set<String>
  public var remove: Set<String>

  public init(add: Set<String> = [], remove: Set<String> = []) {
    self.add = add
    self.remove = remove
  }

  /// Folds a later change in: the newest wins for a label named by both.
  public mutating func combine(add newAdd: Set<String>, remove newRemove: Set<String>) {
    add.formUnion(newAdd); add.subtract(newRemove)
    remove.formUnion(newRemove); remove.subtract(newAdd)
  }

  public var isEmpty: Bool { add.isEmpty && remove.isEmpty }
}

/// How long a queued change waits before its next attempt: 5 s, 30 s, 2 min, then 2 min again.
/// A successful sync or coming back to the app retries at once, whatever the schedule says.
public enum LabelEditRetry {
  public static let schedule: [TimeInterval] = [5, 30, 120]

  /// The wait after `attempts` failed attempts in a row (the first failure is attempts == 1).
  public static func delay(afterAttempts attempts: Int) -> TimeInterval {
    schedule[min(max(attempts, 1), schedule.count) - 1]
  }
}
