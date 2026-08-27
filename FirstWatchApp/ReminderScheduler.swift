import Foundation
import UserNotifications

/// Schedules a daily "haven't hung today" reminder.
///
/// Design: we schedule a single repeating local notification at the user's
/// preferred time. The check for "did the user already hang today" is done at
/// delivery by reading the store at fire time is not possible for static UN
/// triggers — so instead the notification fires daily and the user dismisses it
/// if they've already trained. This is the same approach Apple Reminders and
/// most habit apps use (and keeps us off a background-refresh dependency).
///
/// Pure scheduling logic is split into `nextFireDate(after:hour:minute:)` so it
/// can be unit-tested without the notification system.
final class ReminderScheduler: ObservableObject {

    static let dailyReminderId = "hangTracker.dailyReminder"

    /// Requests notification authorization. Idempotent.
    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    /// Schedules a daily reminder at `hour`:`minute`. Removes any previous
    /// reminder first so rescheduling is clean.
    func scheduleDaily(atHour hour: Int = 20, minute: Int = 0) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.dailyReminderId])

        let content = UNMutableNotificationContent()
        content.title = "Time to hang!"
        content.body = "You haven't done your dead hang today. Grab the bar 🌱"
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(hour: hour, minute: minute),
            repeats: true
        )

        let request = UNNotificationRequest(identifier: Self.dailyReminderId,
                                            content: content,
                                            trigger: trigger)
        center.add(request)
    }

    /// Cancels the daily reminder.
    func cancelDaily() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.dailyReminderId])
    }

    /// Pure helper: the next Date at which an hourly reminder would fire, given
    /// the current time. Exposed for unit testing the time math without needing
    /// the notification system. Returns nil for invalid hour/minute.
    static func nextFireDate(after now: Date = Date(),
                             hour: Int = 20,
                             minute: Int = 0,
                             calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        // If the time today has already passed, schedule for tomorrow.
        let next = calendar.nextDate(after: now,
                                     matching: comps,
                                     matchingPolicy: .nextTime)
        return next
    }

    /// Whether the user has at least one session on `now`'s calendar day. Used
    /// by the UI to show "done for today".
    static func hasHungToday(_ sessions: [HangSession],
                             now: Date = Date(),
                             calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        let todayKey = dayKey(for: now, calendar: calendar)
        return sessions.contains { $0.dayKey(calendar: calendar) == todayKey }
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> HangSession.DayKey {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return HangSession.DayKey(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }
}
