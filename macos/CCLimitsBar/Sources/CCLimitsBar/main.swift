// Menu bar индикатор лимитов Claude Code: два кольца (5ч и 7д) в статус-баре.
//
//   длина дуги   - сколько бюджета выработано
//   цвет дуги    - зона накопленного ТЕМПА по всему окну: бирюзовый недобор,
//                  зелёный в темпе, янтарный быстровато, красный слишком быстро
//   бледная дуга - куда придёшь к сбросу, если накопленный темп сохранится
//   диск в центре - РЫВОК: темп последней единицы окна (час из пяти, сутки из
//                  семи). Диаметр - куда пришёл бы к сбросу на этом рывке,
//                  полный диск = вдвое быстрее допустимого. Цвет - та же шкала
//   красный ободок - бюджет выбран, дальше идёт резерв (чужая доля)
//
// Красный не означает "лимиты кончились": кончившиеся лимиты и так видно по
// отказам агентов. Красный означает "жжёшь слишком быстро" - то, ради чего
// индикатор и нужен.
//
// Считает всё Python: `cc-limits --indicator` отдаёт готовые зоны и прогноз.
// Это кэш-only вызов, в сеть не лезет.

import AppKit
import CCLimitsCore

// MARK: - Модель (форма JSON из `cc-limits --indicator`)

struct WindowStatus: Decodable {
    let pct: Double?
    let raw_pct: Double?
    let reserve: Double?
    let remain: Double?
    let dev: Double?
    let expected: Double?
    let rate: Double?
    let n: Int?
    let eta: Double?
    let running_out: Bool?
    let level: String?
    let pace: Double?
    let avg_rate: Double?
    let projected_pct: Double?
    let dry: Double?
    let in_reserve: Bool?
    let burst_pace: Double?
    let burst_level: String?
    let burst_projected_pct: Double?
}

struct AccountStatus: Decodable {
    let label: String
    let `default`: Bool
    let age: Double?
    let error: String?
    /// данные старше TTL: фоновое обновление их не обновило
    let stale: Bool?
    /// почему не обновилось - истёкший токен, пауза после 429 и т.п.
    let stale_reason: String?
    /// машинный код причины: token_expired, no_scope, rate_limited, other
    let stale_code: String?
    let windows: [String: WindowStatus]
}

struct Snapshot: Decodable {
    let accounts: [AccountStatus]
}

let CORE_WINDOWS: [(label: String, key: String)] = [
    (label: "5ч", key: "five_hour"),
    (label: "7д", key: "seven_day"),
]

// MARK: - Форматирование (косметика; числа и зоны считает Python)

func fmtDur(_ secOpt: Double?) -> String {
    guard let secRaw = secOpt else { return "?" }
    let sec = Int(max(0, secRaw))
    let d = sec / 86400
    let hRem = sec % 86400
    let h = hRem / 3600
    let m = (hRem % 3600) / 60
    if d > 0 { return "\(d)д \(h)ч \(String(format: "%02d", m))м" }
    if h > 0 { return "\(h)ч \(String(format: "%02d", m))м" }
    if m > 0 { return "\(m)м" }
    return "\(sec)с"
}

func colorFor(level: String?) -> NSColor {
    switch level {
    case "red": return .systemRed
    // янтарный, а не systemYellow: жёлтый на светлом менюбаре не виден
    case "yellow": return .systemOrange
    case "green": return .systemGreen
    case "idle": return .systemTeal
    default: return .secondaryLabelColor
    }
}

/// Человеческая формулировка зоны темпа.
func paceWord(_ st: WindowStatus) -> String {
    switch st.level {
    case "red": return "слишком быстро"
    case "yellow": return "быстровато"
    case "green": return "в темпе"
    case "idle": return "недобор"
    default: return "темп ещё не ясен"
    }
}

// MARK: - Иконка статус-бара: два кольца-гейджа (слева 5ч, справа 7д)

func makeIcon(five: WindowStatus?, week: WindowStatus?, stale: Bool = false) -> NSImage {
    // высота под реальную толщину менюбара: на маках с чёлкой она больше
    let height = max(18, NSStatusBar.system.thickness - 2)
    let diameter = height - 5
    let gap: CGFloat = 3.5
    let pad: CGFloat = 1.5
    let width = pad * 2 + diameter * 2 + gap

    // drawingHandler, а не готовый растр: AppKit перерисовывает его под
    // backingScaleFactor экрана (чётко на любом Retina) и под текущую
    // светлую/тёмную тему менюбара
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        // устаревшие цифры гасим: по ним нельзя решать, сколько ещё работать,
        // а нарисованные в полную силу они ничем не отличаются от свежих
        if stale {
            NSGraphicsContext.current?.cgContext.setAlpha(0.55)
        }
        let y = (rect.height - diameter) / 2
        drawGauge(in: CGRect(x: pad, y: y, width: diameter, height: diameter), status: five)
        drawGauge(in: CGRect(x: pad + diameter + gap, y: y, width: diameter, height: diameter), status: week)
        return true
    }
    image.isTemplate = false
    return image
}

func drawGauge(in rect: CGRect, status: WindowStatus?) {
    // внешний поясок оставлен под сигнал "ушёл в резерв", поэтому кольцо
    // всегда немного утоплено - иначе геометрия дёргалась бы при включении
    let alertInset: CGFloat = 1.6
    let stroke = rect.width * 0.17
    let radius = (rect.width - stroke) / 2 - alertInset
    let center = CGPoint(x: rect.midX, y: rect.midY)

    // butt, а не round: круглый колпачок на 1% рисует заметную точку, то есть
    // показывает больше, чем выработано
    func arc(from start: CGFloat, sweep: CGFloat, color: NSColor) {
        guard sweep > 0.5 else { return }
        let path = NSBezierPath()
        if sweep >= 359.5 {
            path.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        } else {
            path.appendArc(withCenter: center, radius: radius, startAngle: start,
                           endAngle: start - sweep, clockwise: true)
        }
        path.lineWidth = stroke
        path.lineCapStyle = .butt
        color.setStroke()
        path.stroke()
    }

    // Только два сегмента: выработано и остаток. Прогноз по накопленному
    // темпу жил тут третьей бледной дугой - в 17 точках она перетягивала
    // внимание на себя, будучи тяжелее реальных данных. Куда идёшь, теперь
    // показывает диск рывка, а накопленный прогноз остался в меню.
    let color = colorFor(level: status?.level)
    let used = min(100.0, max(0.0, status?.pct ?? 0))
    let usedDeg = CGFloat(used) * 3.6
    // сегменты встык, без наложения: наложенные полосы одного радиуса
    // смешиваются краями и дают кайму вокруг цвета
    arc(from: 90 - usedDeg, sweep: 360 - usedDeg,
        color: NSColor.labelColor.withAlphaComponent(0.45))
    if status?.pct != nil {
        arc(from: 90, sweep: usedDeg, color: color)
    }

    // рывок - отдельный канал: кольцо отвечает "как иду по окну", диск -
    // "как ем прямо сейчас". Радиус линеен по темпу рывка, полный диск
    // означает вдвое быстрее равномерного
    if let burst = status?.burst_pace {
        let hole = radius - stroke / 2
        let r = hole * 0.94 * CGFloat(min(1.0, max(0.0, burst / 2.0)))
        if r > 0.35 {
            colorFor(level: status?.burst_level).setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r,
                                        width: r * 2, height: r * 2)).fill()
        }
    }

    // бюджет выбран, дальше идёт чужая доля: агенты ещё работают, сам этого
    // не заметишь, поэтому отдельный канал - ободок по краю
    if status?.in_reserve == true {
        let r = radius + stroke / 2 + 1.0
        let ring = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r,
                                               width: r * 2, height: r * 2))
        ring.lineWidth = 1.0
        NSColor.systemRed.setStroke()
        ring.stroke()
    }
}

// MARK: - Строка окна в меню

final class WindowRowView: NSView {
    private let title: String
    private let status: WindowStatus?

    init(title: String, status: WindowStatus?) {
        self.title = title
        self.status = status
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let color = colorFor(level: status?.level)
        let strong = NSFont.systemFont(ofSize: 13, weight: .medium)
        let small = NSFont.systemFont(ofSize: 11)

        (title as NSString).draw(
            at: CGPoint(x: 16, y: bounds.height - 22),
            withAttributes: [.font: strong, .foregroundColor: NSColor.labelColor])

        guard let st = status, let pct = st.pct else {
            ("нет данных" as NSString).draw(
                at: CGPoint(x: 48, y: bounds.height - 22),
                withAttributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])
            return
        }

        // шкала: заполненное - выработано, бледное продолжение - прогноз
        let barRect = CGRect(x: 48, y: bounds.height - 20, width: 170, height: 8)
        let used = min(100.0, max(0.0, pct))
        let projected = min(100.0, max(used, st.projected_pct ?? used))
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4).fill()
        color.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: CGRect(x: barRect.minX, y: barRect.minY,
                                         width: barRect.width * projected / 100,
                                         height: barRect.height),
                     xRadius: 4, yRadius: 4).fill()
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: barRect.minX, y: barRect.minY,
                                         width: barRect.width * used / 100,
                                         height: barRect.height),
                     xRadius: 4, yRadius: 4).fill()

        let right = NSMutableParagraphStyle()
        right.alignment = .right
        (String(format: "%.0f%%", pct) as NSString).draw(
            in: CGRect(x: 226, y: bounds.height - 23, width: 118, height: 18),
            withAttributes: [.font: strong, .foregroundColor: color,
                             .paragraphStyle: right])

        var tail = [paceWord(st)]
        if let pace = st.pace {
            tail.append(String(format: "темп x%.2f", pace))
        }
        if let burst = st.burst_pace {
            tail.append(String(format: "рывок x%.2f", burst))
        }
        if let remain = st.remain {
            tail.append("сброс \(fmtDur(remain))")
        }
        (tail.joined(separator: "  ·  ") as NSString).draw(
            at: CGPoint(x: 48, y: bounds.height - 38),
            withAttributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])
    }
}

func textItem(_ text: String, size: CGFloat = 11,
              color: NSColor = .secondaryLabelColor, bold: Bool = false) -> NSMenuItem {
    let item = NSMenuItem()
    item.attributedTitle = NSAttributedString(string: text, attributes: [
        .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
        .foregroundColor: color,
    ])
    item.isEnabled = true
    return item
}

// MARK: - Автообновление истёкшего токена

/// Claude Code обновляет OAuth-токен только когда сам им пользуется. Если в
/// Keychain лежит просроченный токен, а claude в этот момент никто не
/// запускает, обновление лимитов будет падать часами - ровно это и случилось.
/// Короткий запрос заставляет Claude Code обновить связку.
///
/// Запрос тратит бюджет, который этот индикатор и бережёт, поэтому поводов
/// для него ровно один (код token_expired), повторы редки, а серия неудач
/// останавливает попытки вместо того, чтобы жечь бюджет в пустоту.
final class TokenRefresher {
    private static let timeout: TimeInterval = 120
    private static let noteLifetime: TimeInterval = 600

    private var inFlight = false
    /// запрос сделан, ждём следующий снимок: успех определяем по тому, ушла
    /// ли причина, а не по коду возврата - claude может завершиться нулём,
    /// не продлив связку
    private var awaitingVerdict = false
    private var lastAttempt: Date?
    private var failures = 0
    private var noteText: String?
    private var noteUntil: Date?

    var note: String? {
        guard let noteText else { return nil }
        if let until = noteUntil, until < Date() { return nil }
        return noteText
    }

    private let binary: String? = {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func refreshIfNeeded(_ snapshot: Snapshot?, enabled: Bool,
                         completion: @escaping () -> Void) {
        let expired = snapshot?.accounts.contains {
            $0.stale == true && $0.stale_code == "token_expired"
        } ?? false

        func state() -> TokenRefreshPolicy.State {
            TokenRefreshPolicy.State(
                expired: expired, enabled: enabled, inFlight: inFlight,
                awaitingVerdict: awaitingVerdict, failures: failures,
                lastAttempt: lastAttempt)
        }

        // состояние пересобираем после приговора: иначе решение о новом
        // запросе принималось бы по счётчику неудач, снятому до инкремента
        if let succeeded = TokenRefreshPolicy.verdict(state()) {
            awaitingVerdict = false
            if succeeded {
                failures = 0
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                say("Вход продлён автоматически в \(f.string(from: Date()))",
                    lasting: Self.noteLifetime)
            } else {
                failures += 1
                say(failures >= TokenRefreshPolicy.maxFailures
                    ? "Продлить вход не вышло, запусти claude вручную"
                    : "Продлить вход не вышло, повтор позже", lasting: nil)
            }
        }

        guard TokenRefreshPolicy.shouldLaunch(state()) else { return }
        guard let binary else {
            say("claude не найден, вход не продлить", lasting: nil)
            return
        }

        inFlight = true
        lastAttempt = Date()
        say("Продлеваю вход...", lasting: nil)

        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binary)
            proc.arguments = ["-p", "ок"]
            // переменную убираем явно: с ней claude возьмёт токен из
            // окружения и к связке в Keychain не притронется - то есть не
            // продлит ровно то, что протухло
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
            proc.environment = env
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()

            var launched = false
            do {
                try proc.run()
                launched = true
                let deadline = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout,
                                                  execute: deadline)
                proc.waitUntilExit()
                deadline.cancel()
            } catch {
                launched = false
            }

            DispatchQueue.main.async {
                self.inFlight = false
                if launched {
                    // приговор вынесет следующий снимок
                    self.awaitingVerdict = true
                } else {
                    self.failures += 1
                    self.say("claude не запустился, вход не продлить", lasting: nil)
                }
                completion()
            }
        }
    }

    private func say(_ text: String, lasting: TimeInterval?) {
        noteText = text
        noteUntil = lasting.map { Date().addingTimeInterval($0) }
    }
}

// MARK: - Опрос cc-limits

final class LimitsFetcher {
    private func run(_ arguments: [String], captureOutput: Bool,
                     completion: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ccLimitsBinary)
            proc.arguments = arguments
            let outPipe = Pipe()
            proc.standardOutput = captureOutput ? outPipe : Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let data = captureOutput ? outPipe.fileHandleForReading.readDataToEndOfFile() : nil
            proc.waitUntilExit()
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// Снимок по кэшу, без сети (как --statusline): не блокирует таймер опроса.
    func fetch(completion: @escaping (Snapshot?) -> Void) {
        run(["--indicator"], captureOutput: true) { data in
            guard let data,
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
                completion(nil)
                return
            }
            completion(snapshot)
        }
    }

    /// Принудительное обновление по сети; completion - когда процесс завершился.
    func refresh(completion: @escaping () -> Void) {
        run(["--refresh"], captureOutput: false) { _ in completion() }
    }
}

// MARK: - Контроллер статус-бара

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fetcher = LimitsFetcher()
    private var timer: Timer?
    private var latest: Snapshot?
    private var prefs = BarPrefs.load()
    private lazy var settings = SettingsWindowController()
    private let tokenRefresher = TokenRefresher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.image = makeIcon(five: nil, week: nil)
        statusItem.button?.toolTip = "cc-limits: опрашиваю..."
        rebuildMenu()
        poll()
        restartTimer()
        NotificationCenter.default.addObserver(
            forName: .barPrefsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.prefs = BarPrefs.load()
            self.restartTimer()
            self.updateIcon()
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: prefs.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        fetcher.fetch { [weak self] snapshot in
            guard let self else { return }
            self.latest = snapshot
            self.updateIcon()
            self.rebuildMenu()
            self.tokenRefresher.refreshIfNeeded(
                snapshot, enabled: self.prefs.autoRefreshToken) { [weak self] in
                guard let self else { return }
                self.rebuildMenu()
                // связка обновилась - просим цифры заново, не дожидаясь такта
                self.fetcher.refresh { [weak self] in self?.poll() }
            }
        }
    }

    private func primaryAccount() -> AccountStatus? {
        guard let accs = latest?.accounts, !accs.isEmpty else { return nil }
        if let pinned = prefs.account, let acc = accs.first(where: { $0.label == pinned }) {
            return acc
        }
        // иначе первый, у кого вообще есть цифры: запись без scope ничего не
        // покажет, а иконка должна показывать что-то осмысленное
        return accs.first(where: { $0.error == nil && !$0.windows.isEmpty })
            ?? accs.first(where: { $0.default })
            ?? accs.first
    }

    private func updateIcon() {
        let primary = primaryAccount()
        statusItem.button?.image = makeIcon(
            five: primary?.windows["five_hour"],
            week: primary?.windows["seven_day"],
            stale: primary?.stale == true
        )
        statusItem.button?.toolTip = tooltipText(primary)
    }

    private func tooltipText(_ acc: AccountStatus?) -> String {
        guard let acc else { return "cc-limits: нет данных" }
        if let err = acc.error { return "\(acc.label): \(err)" }
        if acc.stale == true, let reason = acc.stale_reason {
            return "\(acc.label): данные \(fmtDur(acc.age)) назад\n\(reason)"
        }
        func part(_ name: String, _ w: WindowStatus?) -> String {
            guard let w, let p = w.pct else { return "\(name) ?" }
            return String(format: "%@ %.0f%% (%@)", name, p, paceWord(w))
        }
        return [acc.label,
                part("5ч", acc.windows["five_hour"]),
                part("7д", acc.windows["seven_day"])].joined(separator: "\n")
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        guard let accs = latest?.accounts, !accs.isEmpty else {
            menu.addItem(textItem("нет данных"))
            appendFooter(menu)
            statusItem.menu = menu
            return
        }

        let multi = accs.count > 1
        for (i, acc) in accs.enumerated() {
            if multi {
                menu.addItem(textItem(acc.label, size: 12, color: .labelColor, bold: true))
            }

            if let err = acc.error {
                menu.addItem(textItem("   " + err, color: .systemOrange))
            } else {
                for w in CORE_WINDOWS {
                    let item = NSMenuItem()
                    item.view = WindowRowView(title: w.label, status: acc.windows[w.key])
                    menu.addItem(item)
                }
                if let five = acc.windows["five_hour"], five.in_reserve == true {
                    menu.addItem(textItem("   бюджет 5ч выбран, дальше идёт резерв",
                                          color: .systemRed))
                }
                if let week = acc.windows["seven_day"], week.in_reserve == true {
                    menu.addItem(textItem("   бюджет 7д выбран, дальше идёт резерв",
                                          color: .systemRed))
                }
                for w in CORE_WINDOWS {
                    guard let st = acc.windows[w.key], st.running_out == true else { continue }
                    menu.addItem(textItem(String(
                        format: "   %@: на этом рывке бюджет кончится за %@ до сброса",
                        w.label, fmtDur((st.remain ?? 0) - (st.eta ?? 0)))))
                }
                if acc.stale == true, let reason = acc.stale_reason {
                    menu.addItem(textItem("   данные \(fmtDur(acc.age)) назад, обновить не вышло:"))
                    menu.addItem(textItem("   \(reason)"))
                } else if let age = acc.age, age > 120 {
                    menu.addItem(textItem("   обновлено \(fmtDur(age)) назад"))
                }
                if i == 0, let note = tokenRefresher.note {
                    menu.addItem(textItem("   \(note)"))
                }
            }
            if i < accs.count - 1 { menu.addItem(.separator()) }
        }

        appendFooter(menu)
        statusItem.menu = menu
    }

    private func appendFooter(_ menu: NSMenu) {
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Обновить сейчас",
                                 action: #selector(AppDelegate.refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let prefsItem = NSMenuItem(title: "Настройки...",
                                   action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        let quit = NSMenuItem(title: "Выход", action: #selector(AppDelegate.quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func refreshNow() {
        fetcher.refresh { [weak self] in self?.poll() }
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
