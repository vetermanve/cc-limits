import XCTest
@testable import CCLimitsCore

final class LimitsMathTests: XCTestCase {
    private let hour: TimeInterval = 3600
    private let window5h: TimeInterval = 5 * 3600
    private let window7d: TimeInterval = 7 * 24 * 3600
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: зоны

    func testЗоныТемпа() {
        XCTAssertEqual(LimitsMath.zone(pace: nil), .gray)
        XCTAssertEqual(LimitsMath.zone(pace: 0.3), .idle)
        XCTAssertEqual(LimitsMath.zone(pace: 0.5), .green, "ровно на границе - уже в темпе")
        XCTAssertEqual(LimitsMath.zone(pace: 1.0), .green, "ровно равномерный темп")
        XCTAssertEqual(LimitsMath.zone(pace: 1.2), .yellow)
        XCTAssertEqual(LimitsMath.zone(pace: 1.4), .red)
    }

    func testПорогКрасногоЭтоЧетвертьОкнаБезЛимитов() {
        // при pace чуть выше порога сухим остаёшься больше четверти окна
        let justOver = LimitsMath.paceOver + 0.01
        XCTAssertGreaterThan(1 - 1 / justOver, LimitsMath.dryOver)
        let justUnder = LimitsMath.paceOver - 0.01
        XCTAssertLessThan(1 - 1 / justUnder, LimitsMath.dryOver)
    }

    // MARK: прошедшая доля окна

    func testПрошедшаяДоляОкна() {
        let resets = now.addingTimeInterval(window5h / 2)
        XCTAssertEqual(LimitsMath.elapsedPct(resetsAt: resets, window: window5h, now: now)!,
                       50, accuracy: 0.001)
    }

    func testОкноВнеДиапазонаДаётНоль() {
        let past = now.addingTimeInterval(-1)
        XCTAssertNil(LimitsMath.elapsedPct(resetsAt: past, window: window5h, now: now),
                     "окно уже сброшено")
        let far = now.addingTimeInterval(window5h + 1)
        XCTAssertNil(LimitsMath.elapsedPct(resetsAt: far, window: window5h, now: now),
                     "окно ещё не начиналось")
    }

    func testВНачалеОкнаТемпНеСчитается() {
        // прошла минута из пяти часов: знаменатель близок к нулю
        let resets = now.addingTimeInterval(window5h - 60)
        let r = LimitsMath.read(pct: 3, resetsAt: resets, window: window5h,
                                samples: [], lookback: hour, minSpan: 600, now: now)
        XCTAssertNil(r.pace, "иначе темп улетит в тысячи процентов")
        XCTAssertEqual(r.zone, .gray)
    }

    // MARK: накопленный темп

    func testРовноВТемпеПриходитКСбросуНаСотне() {
        let resets = now.addingTimeInterval(window5h / 2)
        let r = LimitsMath.read(pct: 50, resetsAt: resets, window: window5h,
                                samples: [], lookback: hour, minSpan: 600, now: now)
        XCTAssertEqual(r.pace!, 1.0, accuracy: 0.001)
        XCTAssertEqual(r.projectedPct!, 100, accuracy: 0.01)
        XCTAssertEqual(r.dry, 0, accuracy: 0.0001)
        XCTAssertEqual(r.zone, .green)
    }

    func testПеререасходДаётДолюОкнаБезЛимитов() {
        // половина окна прошла, съедено 80%: придёшь к 160% и сядешь раньше
        let resets = now.addingTimeInterval(window5h / 2)
        let r = LimitsMath.read(pct: 80, resetsAt: resets, window: window5h,
                                samples: [], lookback: hour, minSpan: 600, now: now)
        XCTAssertEqual(r.pace!, 1.6, accuracy: 0.001)
        XCTAssertEqual(r.projectedPct!, 160, accuracy: 0.01)
        XCTAssertEqual(r.dry, 1 - 1 / 1.6, accuracy: 0.001)
        XCTAssertEqual(r.zone, .red)
    }

    func testСреднийТемпВПроцентахВЧас() {
        // прошло два часа из пяти, съедено 20%
        let resets = now.addingTimeInterval(window5h - 2 * hour)
        let r = LimitsMath.read(pct: 20, resetsAt: resets, window: window5h,
                                samples: [], lookback: hour, minSpan: 600, now: now)
        XCTAssertEqual(r.avgRatePerHour!, 10, accuracy: 0.001)
    }

    // MARK: рывок

    private func samples(_ pairs: [(TimeInterval, Double)], resets: Date) -> [WindowSample] {
        pairs.map { WindowSample(at: now.addingTimeInterval($0.0), pct: $0.1, resetsAt: resets) }
    }

    func testРывокСчитаетсяПоЗамерамОкна() {
        let resets = now.addingTimeInterval(window5h / 2)
        // за час съедено 10% - вдвое быстрее равномерных 20%/ч? нет, вдвое медленнее
        let s = samples([(-3600, 30), (0, 40)], resets: resets)
        let r = LimitsMath.read(pct: 40, resetsAt: resets, window: window5h,
                                samples: s, lookback: 2 * hour, minSpan: 600, now: now)
        XCTAssertEqual(r.burstRatePerHour!, 10, accuracy: 0.001)
        // равномерный темп пятичасового окна - 20%/ч
        XCTAssertEqual(r.burstPace!, 0.5, accuracy: 0.001)
        XCTAssertEqual(r.burstSamples, 2)
    }

    func testОдногоЗамераМало() {
        let resets = now.addingTimeInterval(window5h / 2)
        let r = LimitsMath.read(pct: 40, resetsAt: resets, window: window5h,
                                samples: samples([(0, 40)], resets: resets),
                                lookback: 2 * hour, minSpan: 600, now: now)
        XCTAssertNil(r.burstRatePerHour, "по одному замеру скорость не вывести")
    }

    func testТесныеЗамерыНеЭкстраполируются() {
        let resets = now.addingTimeInterval(window7d / 2)
        // два замера с разбросом в минуту - неделю по ним не предскажешь
        let s = samples([(-60, 10), (0, 11)], resets: resets)
        let r = LimitsMath.read(pct: 11, resetsAt: resets, window: window7d,
                                samples: s, lookback: 24 * hour, minSpan: 2 * hour, now: now)
        XCTAssertNil(r.burstRatePerHour, "минутного разброса мало для недельного окна")
    }

    func testЗамерыЧужогоОкнаОтбрасываются() {
        let resets = now.addingTimeInterval(window5h / 2)
        let foreign = resets.addingTimeInterval(5 * hour)
        var s = samples([(-3600, 30)], resets: resets)
        s += samples([(0, 90)], resets: foreign)
        let r = LimitsMath.read(pct: 30, resetsAt: resets, window: window5h,
                                samples: s, lookback: 2 * hour, minSpan: 600, now: now)
        XCTAssertNil(r.burstRatePerHour, "остался один замер этого окна")
    }

    func testСтарыеЗамерыЗаГлубинойВыборкиНеУчаствуют() {
        let resets = now.addingTimeInterval(window5h / 2)
        let s = samples([(-5 * 3600, 10), (-3600, 30), (0, 40)], resets: resets)
        let r = LimitsMath.read(pct: 40, resetsAt: resets, window: window5h,
                                samples: s, lookback: 2 * hour, minSpan: 600, now: now)
        XCTAssertEqual(r.burstSamples, 2, "замер пятичасовой давности вне глубины выборки")
    }
}
