// Расчёт темпа расхода. Зеркало того, что считает cc-limits на Python.
//
// Сторовая сборка берёт цифры из statusline Claude Code, а не у CLI, поэтому
// считать темп ей приходится самой. Логика продублирована намеренно и
// покрыта теми же по смыслу проверками: разойдясь, две реализации начнут
// красить одно и то же состояние по-разному.
//
// Цвет кодирует СКОРОСТЬ поедания бюджета, а не остаток: красный значит
// "жгу слишком быстро", а не "лимиты кончились".

import Foundation

public enum PaceZone: String, Equatable {
    case idle, green, yellow, red, gray
}

/// Замер окна: сколько выработано и когда окно сбрасывается.
public struct WindowSample: Equatable {
    public let at: Date
    public let pct: Double
    public let resetsAt: Date

    public init(at: Date, pct: Double, resetsAt: Date) {
        self.at = at
        self.pct = pct
        self.resetsAt = resetsAt
    }
}

public struct WindowReading: Equatable {
    public let pct: Double
    public let remaining: TimeInterval?
    /// сколько окна прошло, в процентах
    public let expected: Double?
    /// накопленный темп в долях равномерного
    public let pace: Double?
    public let zone: PaceZone
    public let avgRatePerHour: Double?
    /// куда придёшь к сбросу при сохранении накопленного темпа
    public let projectedPct: Double?
    /// какую долю окна просидишь без лимитов
    public let dry: Double
    public let burstRatePerHour: Double?
    public let burstPace: Double?
    public let burstZone: PaceZone
    public let burstSamples: Int
}

public enum LimitsMath {
    /// Пока окно прошло меньше чем на столько, темп не считаем: знаменатель
    /// близок к нулю и отношение улетает в тысячи процентов, ничего не
    /// говоря о реальной скорости.
    public static let minElapsedPct = 2.0
    /// К сбросу съешь меньше половины - можно жать сильнее.
    public static let paceUnder = 0.5
    /// Сухим больше четверти окна - это уже перебор.
    public static let dryOver = 0.25
    public static var paceOver: Double { 1.0 / (1.0 - dryOver) }
    /// Замеры считаем принадлежащими одному окну, если моменты сброса
    /// совпадают с точностью до этого зазора.
    public static let sameWindowSlack: TimeInterval = 120

    public static func zone(pace: Double?) -> PaceZone {
        guard let pace else { return .gray }
        if pace > paceOver { return .red }
        if pace > 1.0 { return .yellow }
        if pace < paceUnder { return .idle }
        return .green
    }

    /// Доля окна, которая уже прошла, в процентах. nil - момент сброса вне окна.
    public static func elapsedPct(resetsAt: Date, window: TimeInterval,
                                  now: Date) -> Double? {
        let start = resetsAt.addingTimeInterval(-window)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0, elapsed <= window else { return nil }
        return elapsed / window * 100
    }

    /// Скорость расхода в процентах в час по замерам текущего окна.
    /// nil - замеров мало или они слишком тесно стоят: экстраполировать
    /// неделю по шести минутам наблюдений нельзя.
    public static func burnRate(samples: [WindowSample], resetsAt: Date,
                                lookback: TimeInterval, minSpan: TimeInterval,
                                now: Date) -> (rate: Double, count: Int)? {
        let points = samples
            .filter { abs($0.resetsAt.timeIntervalSince(resetsAt)) < sameWindowSlack }
            .filter { now.timeIntervalSince($0.at) <= lookback }
            .sorted { $0.at < $1.at }
        guard points.count >= 2 else { return nil }
        let span = points[points.count - 1].at.timeIntervalSince(points[0].at)
        guard span >= minSpan else { return nil }
        let hours = span / 3600
        let delta = points[points.count - 1].pct - points[0].pct
        return (delta / hours, points.count)
    }

    public static func read(pct: Double, resetsAt: Date?, window: TimeInterval,
                           samples: [WindowSample], lookback: TimeInterval,
                           minSpan: TimeInterval, now: Date = Date()) -> WindowReading {
        let remaining = resetsAt.map { $0.timeIntervalSince(now) }
        let expected = resetsAt.flatMap {
            elapsedPct(resetsAt: $0, window: window, now: now)
        }

        var pace: Double?
        var avgRate: Double?
        if let expected, expected >= minElapsedPct {
            pace = pct / expected
            let elapsedHours = expected / 100 * window / 3600
            if elapsedHours > 0 { avgRate = pct / elapsedHours }
        }

        var burstRate: Double?
        var burstCount = 0
        if let resetsAt,
           let measured = burnRate(samples: samples, resetsAt: resetsAt,
                                   lookback: lookback, minSpan: minSpan, now: now) {
            burstRate = measured.rate
            burstCount = measured.count
        }
        let evenRate = 100 / (window / 3600)
        let burstPace = burstRate.map { $0 / evenRate }

        return WindowReading(
            pct: pct,
            remaining: remaining,
            expected: expected,
            pace: pace,
            zone: zone(pace: pace),
            avgRatePerHour: avgRate,
            projectedPct: pace.map { $0 * 100 },
            dry: (pace.map { $0 > 1 ? 1 - 1 / $0 : 0 }) ?? 0,
            burstRatePerHour: burstRate,
            burstPace: burstPace,
            burstZone: zone(pace: burstPace),
            burstSamples: burstCount)
    }
}
