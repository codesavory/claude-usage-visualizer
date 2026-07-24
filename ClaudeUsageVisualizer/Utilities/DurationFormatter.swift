import Foundation

enum DurationFormatter {
    static func compact(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        if m > 0 {
            return "\(m)m"
        }
        return "\(total)s"
    }

    static func daysAndHours(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// Wall-clock time a window resets at, e.g. "9pm" or "2:40pm".
    ///
    /// Locale-aware: the "j" template renders 24-hour time ("21:00") wherever
    /// that is the convention, and the lowercasing is a no-op there. Minutes
    /// are dropped on the hour so the common case stays short, and the space
    /// before AM/PM is squeezed out to fit the caption row.
    static func clockTime(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let minute = calendar.component(.minute, from: date)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(minute == 0 ? "j" : "jmm")
        let text = formatter.string(from: date).lowercased()
        return String(text.filter { !$0.isWhitespace })
    }

    /// Wall-clock reset time prefixed with the weekday, e.g. "Sat 11pm". For
    /// windows more than a day out, where the time on its own is ambiguous.
    static func clockTimeWithWeekday(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        let weekday = formatter.string(from: date)
        return "\(weekday) \(clockTime(date, calendar: calendar, locale: locale))"
    }

    static func short(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }
}
