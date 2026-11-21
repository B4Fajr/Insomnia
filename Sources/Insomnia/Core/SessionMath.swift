import Foundation

/// Pure session arithmetic. No clocks, no side effects.
enum SessionMath {
    /// Shortest session we accept.
    static let minimumDuration: TimeInterval = 60

    /// Clamp a requested duration into `[minimumDuration, maxDuration]`.
    static func clamp(_ duration: TimeInterval, maxDuration: TimeInterval) -> TimeInterval {
        let upper = max(maxDuration, minimumDuration)
        return min(max(duration, minimumDuration), upper)
    }

    /// End time for a session starting at `start`.
    static func endsAt(start: Date, duration: TimeInterval, maxDuration: TimeInterval) -> Date {
        start.addingTimeInterval(clamp(duration, maxDuration: maxDuration))
    }

    /// Fresh session starting now.
    static func newSession(
        now: Date, duration: TimeInterval, maxDuration: TimeInterval, trigger: Session.Trigger? = nil
    ) -> Session {
        Session(startedAt: now, endsAt: endsAt(start: now, duration: duration, maxDuration: maxDuration), trigger: trigger)
    }

    /// Push `endsAt` out by `extra` seconds, never past `now + maxDuration`.
    /// Extending an already-expired session restarts the countdown from `now`.
    static func extended(_ session: Session, by extra: TimeInterval, now: Date, maxDuration: TimeInterval) -> Session {
        let base = max(session.endsAt, now)
        let ceiling = now.addingTimeInterval(max(maxDuration, minimumDuration))
        let proposed = base.addingTimeInterval(max(extra, 0))
        let newEnd = min(proposed, ceiling)
        var s = session
        s.extensions.append(newEnd.timeIntervalSince(session.endsAt))
        s.endsAt = newEnd
        return s
    }

    /// Seconds from `now` to `endsAt`, floored at zero.
    static func remaining(until endsAt: Date, at now: Date) -> TimeInterval {
        max(endsAt.timeIntervalSince(now), 0)
    }

    static func isExpired(endsAt: Date, at now: Date) -> Bool {
        endsAt.timeIntervalSince(now) <= 0
    }

    /// Minute-granularity remaining time: "3d 2h", "2h 14m", "14m", "<1m".
    /// Zero secondary units are dropped ("2h", "3d"). Seconds are floored.
    static func formatRemaining(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(max(interval, 0) / 60)
        if totalMinutes < 1 { return "<1m" }
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    /// Live menu bar countdown in whole minutes and a fixed `shape`.
    /// Round up so a fresh 30-minute session opens on `30m` and a session
    /// with time left never displays zero.
    static func formatCountdown(remaining: TimeInterval, shape: CountdownShape) -> String {
        let totalMinutes = Int((max(remaining, 0) / 60).rounded(.up))
        let minutes = totalMinutes % 60
        func clock(hours: Int) -> String {
            String(format: "%d:%02d", hours, minutes)
        }
        switch shape {
        case .days:
            let hours = totalMinutes / 60
            let days = hours / 24
            guard days > 0 else { return clock(hours: hours) }
            return "\(days)d " + clock(hours: hours % 24)
        case .hours:
            return clock(hours: totalMinutes / 60)
        case .minutes:
            return String(format: "%02dm", totalMinutes)
        }
    }

    /// Next minute boundary after `now`, measured from the session deadline.
    static func nextMinuteBoundary(after now: Date, relativeTo deadline: Date) -> Date {
        let minutes = (now.timeIntervalSince(deadline) / 60).rounded(.down)
        return deadline.addingTimeInterval((minutes + 1) * 60)
    }

    /// Next whole wall-clock second after `now` (for the 1 Hz countdown timer).
    static func nextSecondBoundary(after now: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: floor(now.timeIntervalSinceReferenceDate) + 1)
    }
}

/// Shape of the live menu bar countdown.
///
/// Chosen once from the session's initial duration and held for the whole
/// session so the status item keeps a stable width instead of jittering as
/// units drop off. The only mid-session change is `days` losing its day
/// component once fewer than 24 hours remain.
enum CountdownShape: Equatable, Sendable {
    /// `Nd H:MM` while the display rounds to at least a day, then `H:MM`.
    case days
    /// `H:MM` for the whole session, even under an hour (`0:04`).
    case hours
    /// `MMm` for the whole session (`04m`, `01m`).
    case minutes

    init(initialDuration: TimeInterval) {
        if initialDuration >= 86400 {
            self = .days
        } else if initialDuration >= 3600 {
            self = .hours
        } else {
            self = .minutes
        }
    }
}
