// Когда индикатору позволено самому продлевать вход.
//
// Продление стоит немного того самого бюджета, который индикатор бережёт,
// поэтому решение вынесено отдельно и покрыто тестами: ошибка здесь не
// рисует кривой пиксель, а молча жжёт лимиты в фоне.

import Foundation

public enum TokenRefreshPolicy {
    /// Не чаще раза в десять минут: связка живёт часами, чаще незачем.
    public static let retryInterval: TimeInterval = 600
    /// После трёх неудач подряд перестаём пытаться: если не помогло трижды,
    /// не поможет и на тридцатый раз, а бюджет кончится.
    public static let maxFailures = 3

    public struct State {
        public var expired: Bool
        public var enabled: Bool
        public var inFlight: Bool
        public var awaitingVerdict: Bool
        public var failures: Int
        public var lastAttempt: Date?

        public init(expired: Bool, enabled: Bool = true, inFlight: Bool = false,
                    awaitingVerdict: Bool = false, failures: Int = 0,
                    lastAttempt: Date? = nil) {
            self.expired = expired
            self.enabled = enabled
            self.inFlight = inFlight
            self.awaitingVerdict = awaitingVerdict
            self.failures = failures
            self.lastAttempt = lastAttempt
        }
    }

    /// Приговор предыдущей попытке: nil - приговаривать нечего.
    /// Успех определяем по тому, ушла ли причина, а не по коду возврата:
    /// claude может завершиться нулём, не продлив связку.
    public static func verdict(_ s: State) -> Bool? {
        guard s.awaitingVerdict, !s.inFlight else { return nil }
        return !s.expired
    }

    /// Делать ли запрос прямо сейчас.
    public static func shouldLaunch(_ s: State, now: Date = Date()) -> Bool {
        guard s.enabled, s.expired, !s.inFlight else { return false }
        guard s.failures < maxFailures else { return false }
        if let last = s.lastAttempt, now.timeIntervalSince(last) < retryInterval {
            return false
        }
        return true
    }
}
