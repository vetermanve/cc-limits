// Окно настроек: аккаунты, резервы, поведение бара, автозапуск.
//
// Конфиг один и тот же, что у CLI - $CLAUDE_CONFIG_DIR/cc-limits.json.
// Записываем его только через проверку: кандидат уходит во временный файл,
// его читает `cc-limits --check-config` тем же кодом, что читает рабочий
// конфиг, и лишь при нулевом коде возврата файл подменяется. Так валидация
// не раздваивается на два языка и не расходится с ними.

import AppKit
import CCLimitsCore
import SwiftUI

// MARK: - запуск cc-limits

let claudeConfigDir: String =
    ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.claude")

let ccLimitsBinary: String = {
    let candidates = [
        NSHomeDirectory() + "/.local/bin/cc-limits",
        "/opt/homebrew/bin/cc-limits",
        "/usr/local/bin/cc-limits",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "cc-limits"
}()

func runCC(_ args: [String]) -> (code: Int32, out: Data, err: Data) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ccLimitsBinary)
    proc.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    do {
        try proc.run()
    } catch {
        return (-1, Data(), Data("не запустился \(ccLimitsBinary): \(error.localizedDescription)".utf8))
    }
    // оба потока читаем параллельно: последовательное чтение встанет насмерть,
    // если второй поток заполнит буфер трубы, пока мы ждём первый
    var outData = Data(), errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
    }
    group.wait()
    proc.waitUntilExit()
    return (proc.terminationStatus, outData, errData)
}

// MARK: - настройки самого бара (конфиг CLI их не знает)

struct BarPrefs: Codable {
    var account: String?          // чей кольца на иконке; nil - первый с данными
    var pollInterval: Double = 30

    static var path: String { claudeConfigDir + "/cc-limits-bar.json" }

    static func load() -> BarPrefs {
        guard let data = FileManager.default.contents(atPath: path),
              var p = try? JSONDecoder().decode(BarPrefs.self, from: data) else {
            return BarPrefs()
        }
        p.pollInterval = min(600, max(10, p.pollInterval))
        return p
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
        NotificationCenter.default.post(name: .barPrefsChanged, object: nil)
    }
}

extension Notification.Name {
    static let barPrefsChanged = Notification.Name("ccLimitsBarPrefsChanged")
}

// MARK: - автозапуск

enum LaunchAgent {
    static let label = "com.cc-limits.bar"
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }
    /// Запущены ли мы самим launchd: если нет, свежий plist подхватится только
    /// при следующем входе, и об этом надо сказать прямо, а не делать вид.
    static var managedByLaunchd: Bool {
        (ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "").contains(label)
    }

    static func install() throws {
        let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let dir = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
    }

    static func uninstall() throws {
        if isInstalled {
            try FileManager.default.removeItem(atPath: plistPath)
        }
    }
}

// MARK: - диагностика из `cc-limits --diagnose`

struct DiagAccount: Decodable {
    let name: String
    let label: String
    let source: String
    let fingerprint: String?
    let token_error: String?
    let scope_ok: Bool?
    let cache_age: Double?
    let throttle_left: Double?
    let hidden: Bool?
}

struct DiagSnapshot: Decodable {
    let config: String
    let accounts: [DiagAccount]
    let duplicates: [[String]]
}

// MARK: - редактируемая модель конфига

func argumentLabel(for source: String) -> String? {
    switch source {
    case "env": return "Переменная"
    case "file": return "Путь к файлу"
    case "command": return "Команда"
    case "token": return "Токен"
    default: return nil
    }
}

final class ConfigStore: ObservableObject {
    @Published var accounts: [AccountRow] = []
    @Published var reserve5: String = ""
    @Published var reserve7: String = ""
    @Published var diag: [String: DiagAccount] = [:]
    @Published var duplicates: [[String]] = []
    @Published var diagLoading = false
    @Published var error: String?
    @Published var note: String?

    private var raw: [String: Any] = [:]

    var configPath: String { claudeConfigDir + "/cc-limits.json" }

    private var parsed: ConfigDocument.Parsed {
        ConfigDocument.Parsed(raw: raw, reserve5: reserve5, reserve7: reserve7,
                              accounts: accounts)
    }

    init() {
        load()
        refreshDiagnose()
    }

    func load() {
        let p = ConfigDocument.parse(FileManager.default.contents(atPath: configPath))
        raw = p.raw
        reserve5 = p.reserve5
        reserve7 = p.reserve7
        accounts = p.accounts
    }

    func refreshDiagnose() {
        diagLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runCC(["--diagnose"])
            let snap = try? JSONDecoder().decode(DiagSnapshot.self, from: r.out)
            DispatchQueue.main.async {
                self.diagLoading = false
                guard let snap else {
                    let msg = String(data: r.err, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.error = (msg?.isEmpty == false) ? msg : "не прочитал диагностику аккаунтов"
                    return
                }
                self.diag = Dictionary(uniqueKeysWithValues: snap.accounts.map { ($0.label, $0) })
                self.duplicates = snap.duplicates
            }
        }
    }

    func save() {
        error = nil
        note = nil
        guard let data = try? ConfigDocument.jsonData(parsed) else {
            error = "не собрал JSON из формы"
            return
        }
        let tmp = NSTemporaryDirectory() + "cc-limits-candidate-\(UUID().uuidString).json"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
        } catch {
            self.error = "не записал временный файл: \(error.localizedDescription)"
            return
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let check = runCC(["--check-config", tmp])
        if check.code != 0 {
            let msg = String(data: check.err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            error = msg.isEmpty ? "конфиг не прошёл проверку" : msg
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        } catch {
            self.error = "не записал \(configPath): \(error.localizedDescription)"
            return
        }
        note = "сохранено"
        load()
        refreshDiagnose()
    }

}

// MARK: - окно

// Шапка настроек - тулбар NSTabViewController, а не SwiftUI TabView:
// последний рисует сегментированный контрол внутри контента и добавляет
// лишнюю разделительную линию под титлбаром. Нативное окно настроек держит
// вкладки в самом титлбаре и меняет размер под выбранную вкладку.

/// Пояснение под секцией.
///
/// Сноска в сгруппированной форме попадает в правую колонку и без растяжения
/// прижимается к правому краю. Растянутая же встаёт по краю рамки секции -
/// на десять точек левее заголовка, и у секции получается два разных левых
/// края. Поэтому растягиваем и компенсируем отступ заголовка.
private let sectionHeaderInset: CGFloat = 10

func footnote(_ text: String) -> some View {
    Text(text)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, sectionHeaderInset)
}

func percentField(_ text: Binding<String>, placeholder: String) -> some View {
    HStack(spacing: 6) {
        TextField("", text: text, prompt: Text(placeholder))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 92)
        Text("%").foregroundStyle(.secondary)
    }
}

// MARK: - вкладка «Аккаунты»

struct AccountsTabView: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !store.duplicates.isEmpty {
                    Section {
                        ForEach(store.duplicates, id: \.self) { group in
                            Label(group.joined(separator: ", "), systemImage: "doc.on.doc")
                        }
                    } header: {
                        Text("Один и тот же токен")
                    } footer: {
                        footnote("Цифры под этими именами будут одинаковыми: это одна и та же подписка, описанная дважды.")
                    }
                }

                Section {
                    LabeledContent("5 часов") { percentField($store.reserve5, placeholder: "0") }
                    LabeledContent("7 дней") { percentField($store.reserve7, placeholder: "0") }
                } header: {
                    Text("Резерв по умолчанию")
                } footer: {
                    footnote("Доля окна, которую нельзя тратить. При резерве 20% расход 80% окна показывается как 100% бюджета.")
                }

                ForEach($store.accounts) { $account in
                    accountSection($account)
                }

                Section {
                    Button("Добавить аккаунт") {
                        store.accounts.append(AccountRow(name: "новый"))
                    }
                }
            }
            .formStyle(.grouped)

            footerBar
        }
        .alert("Не удалось сохранить", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } })) {
            Button("Понятно", role: .cancel) { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }

    private func accountSection(_ account: Binding<AccountRow>) -> some View {
        let row = account.wrappedValue
        let diag = store.diag[row.name]
        return Section {
            LabeledContent("Имя") {
                TextField("", text: account.name, prompt: Text("имя аккаунта"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    // в сгруппированной форме колонка значения выравнивается
                    // вправо, и текст в поле уезжает за ней
                    .multilineTextAlignment(.leading)
                    .frame(width: 260)
            }
            LabeledContent("Источник токена") {
                Picker("", selection: account.source) {
                    ForEach(ACCOUNT_SOURCES, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            // аргумент отдельной строкой, а не рядом с источником: иначе
            // аккаунты с аргументом и без разъезжаются по сетке
            if let label = argumentLabel(for: row.source) {
                LabeledContent(label) {
                    Group {
                        if row.source == "token" {
                            SecureField("", text: account.argument)
                        } else {
                            TextField("", text: account.argument)
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 380)
                }
            }
            LabeledContent("Резерв, 5 часов") {
                percentField(account.reserve5, placeholder: "общий")
            }
            LabeledContent("Резерв, 7 дней") {
                percentField(account.reserve7, placeholder: "общий")
            }
            Toggle("Показывать в индикаторе", isOn: Binding(
                get: { !account.wrappedValue.hidden },
                set: { account.hidden.wrappedValue = !$0 }))

            diagnostics(diag, hidden: row.hidden)
        } header: {
            HStack {
                Text(row.name.isEmpty ? "Без имени" : row.name)
                Spacer()
                Button {
                    store.accounts.removeAll { $0.id == row.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Удалить аккаунт из конфига")
            }
        }
    }

    /// Состояние аккаунта. Смысл несут символы, а не цвет текста: раскрашенные
    /// подсказки в настройках читаются как отладочный вывод.
    @ViewBuilder
    private func diagnostics(_ diag: DiagAccount?, hidden: Bool) -> some View {
        if let diag {
            LabeledContent("Отпечаток") {
                Text(diag.fingerprint ?? "токен не прочитан")
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(statusLines(diag, hidden: hidden), id: \.text) { line in
                    Label(line.text, systemImage: line.symbol)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            Label("Состояние не прочитано - нажми «Проверить токены»",
                  systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func statusLines(_ d: DiagAccount, hidden: Bool) -> [(text: String, symbol: String)] {
        var lines: [(text: String, symbol: String)] = []
        if let err = d.token_error {
            lines.append((err, "exclamationmark.triangle"))
        }
        switch d.scope_ok {
        case .some(true):
            lines.append(("Scope user:profile есть, лимиты читаются", "checkmark.seal"))
        case .some(false):
            lines.append(("Нет scope user:profile - лимиты по этому токену недоступны. Его даёт вход через /login, claude setup-token - нет.",
                          "exclamationmark.triangle"))
        case .none:
            lines.append(("Scope не проверялся", "questionmark.circle"))
        }
        if let age = d.cache_age {
            lines.append(("Данные получены \(fmtDur(age)) назад", "clock"))
        } else {
            lines.append(("Данных ещё нет", "clock.badge.questionmark"))
        }
        if let throttle = d.throttle_left, throttle > 0 {
            lines.append(("Пауза после 429, повтор через \(fmtDur(throttle))", "hourglass"))
        }
        if hidden {
            lines.append(("Скрыт: не попадает в кольца, меню и статуслайн. Настройки целы, по cc-limits --account доступен.",
                          "eye.slash"))
        }
        return lines
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            Text(store.configPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(store.diagLoading ? "Проверяю..." : "Проверить токены") {
                store.refreshDiagnose()
            }
            .disabled(store.diagLoading)
            Button("Перечитать") {
                store.load()
                store.refreshDiagnose()
            }
            Button("Сохранить") { store.save() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - вкладка «Индикатор»

struct IndicatorTabView: View {
    @ObservedObject var store: ConfigStore
    @State private var prefs = BarPrefs.load()
    @State private var autostart = LaunchAgent.isInstalled
    @State private var autostartNote: String?

    var body: some View {
        Form {
            Section {
                Picker("Аккаунт на кольцах", selection: Binding(
                    get: { prefs.account ?? "" },
                    set: { prefs.account = $0.isEmpty ? nil : $0; prefs.save() })) {
                    Text("Первый, у кого есть данные").tag("")
                    ForEach(store.accounts.map(\.name), id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Кольца")
            } footer: {
                footnote("В меню всё равно видны все аккаунты, кроме скрытых.")
            }

            Section {
                LabeledContent("Интервал опроса") {
                    HStack(spacing: 8) {
                        Text("\(Int(prefs.pollInterval)) с").monospacedDigit()
                        // значение слева от стрелок: в правой колонке формы
                        // собственный заголовок Stepper встаёт после контрола
                        Stepper("", value: Binding(
                            get: { prefs.pollInterval },
                            set: { prefs.pollInterval = $0; prefs.save() }),
                                in: 10...600, step: 10)
                            .labelsHidden()
                    }
                }
            } header: {
                Text("Опрос")
            } footer: {
                footnote("Читается кэш, в сеть индикатор не ходит: обновление идёт фоном, как у статуслайна.")
            }

            Section {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { autostart },
                    set: { setAutostart($0) }))
            } header: {
                Text("Запуск")
            } footer: {
                footnote(autostartNote ?? LaunchAgent.plistPath)
            }
        }
        .formStyle(.grouped)
    }

    private func setAutostart(_ on: Bool) {
        do {
            if on { try LaunchAgent.install() } else { try LaunchAgent.uninstall() }
            autostart = on
            autostartNote = on && !LaunchAgent.managedByLaunchd
                ? "Агент записан, подхватится при следующем входе в систему."
                : nil
        } catch {
            autostartNote = "Не удалось: \(error.localizedDescription)"
        }
    }
}

// MARK: - окно

final class SettingsTabController: NSTabViewController {
    let store: ConfigStore

    init(store: ConfigStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar

        addTab("Аккаунты", symbol: "person.2", size: NSSize(width: 720, height: 620),
               view: AccountsTabView(store: store))
        addTab("Индикатор", symbol: "gauge.medium", size: NSSize(width: 720, height: 390),
               view: IndicatorTabView(store: store))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateTitle()
    }

    // через selectedTabViewItemIndex, а не через делегатный didSelect:
    // NSTabViewController свой делегат обслуживает сам и переопределённый
    // метод до нас не доходит - окно оставалось "Untitled"
    override var selectedTabViewItemIndex: Int {
        didSet { updateTitle() }
    }

    /// Заголовок окна - имя выбранной вкладки, как в системных настройках.
    /// Сам NSTabViewController его не ставит, окно остаётся "Untitled".
    private func updateTitle() {
        let item = tabViewItems.indices.contains(selectedTabViewItemIndex)
            ? tabViewItems[selectedTabViewItemIndex] : nil
        view.window?.title = item?.label ?? "Лимиты Claude Code"
    }

    private func addTab<V: View>(_ label: String, symbol: String, size: NSSize, view: V) {
        let host = NSHostingController(rootView: view)
        // размер под вкладку: NSTabViewController по нему меняет окно при
        // переключении, иначе короткая вкладка растягивается на высоту длинной
        host.preferredContentSize = size
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        addTabViewItem(item)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let tabs: SettingsTabController

    init() {
        tabs = SettingsTabController(store: ConfigStore())
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        // окно могли открыть после правки конфига руками
        tabs.store.load()
        tabs.store.refreshDiagnose()
        // accessory-приложение окон само не поднимает: без активации окно
        // откроется под чужими и будет выглядеть как будто ничего не произошло
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
