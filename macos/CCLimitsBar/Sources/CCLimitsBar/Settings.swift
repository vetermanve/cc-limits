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

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @State private var prefs = BarPrefs.load()
    @State private var autostart = LaunchAgent.isInstalled
    @State private var autostartNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabView {
                accountsTab.tabItem { Text("Аккаунты") }
                barTab.tabItem { Text("Индикатор") }
            }
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    // --- аккаунты

    private var accountsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(store.duplicates, id: \.self) { group in
                    banner("Один и тот же токен у: " + group.joined(separator: ", ")
                           + ". Цифры под этими именами будут одинаковыми.",
                           color: .orange)
                }

                GroupBox("Резерв по умолчанию") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Доля окна, которую нельзя тратить. При резерве 20% расход 80% окна показывается как 100% бюджета.")
                            .font(.caption).foregroundColor(.secondary)
                        HStack {
                            Text("5ч").frame(width: 24, alignment: .leading)
                            TextField("0", text: $store.reserve5).frame(width: 70)
                            Text("%").foregroundColor(.secondary)
                            Spacer().frame(width: 20)
                            Text("7д").frame(width: 24, alignment: .leading)
                            TextField("0", text: $store.reserve7).frame(width: 70)
                            Text("%").foregroundColor(.secondary)
                        }
                    }.padding(6)
                }

                ForEach($store.accounts) { $acc in
                    accountBox($acc)
                }

                HStack {
                    Button("Добавить аккаунт") {
                        store.accounts.append(AccountRow(name: "новый"))
                    }
                    Button(store.diagLoading ? "Проверяю..." : "Проверить токены") {
                        store.refreshDiagnose()
                    }.disabled(store.diagLoading)
                }
            }.padding(16)
        }
    }

    private func accountBox(_ acc: Binding<AccountRow>) -> some View {
        let d = store.diag[acc.wrappedValue.name]
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Имя").frame(width: 70, alignment: .leading)
                    TextField("имя аккаунта", text: acc.name).frame(width: 180)
                    Spacer()
                    Toggle("Показывать", isOn: Binding(
                        get: { !acc.wrappedValue.hidden },
                        set: { acc.hidden.wrappedValue = !$0 }))
                        .toggleStyle(.switch)
                    Button(role: .destructive) {
                        store.accounts.removeAll { $0.id == acc.wrappedValue.id }
                    } label: { Image(systemName: "trash") }
                }
                if acc.wrappedValue.hidden {
                    Text("Скрыт: не попадает в кольца, меню и статуслайн. Настройки целы, по cc-limits --account он по-прежнему доступен.")
                        .font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    Text("Источник").frame(width: 70, alignment: .leading)
                    Picker("", selection: acc.source) {
                        ForEach(ACCOUNT_SOURCES, id: \.self) { Text($0) }
                    }.labelsHidden().frame(width: 140)
                    if let label = argumentLabel(for: acc.wrappedValue.source) {
                        Text(label).foregroundColor(.secondary)
                        if acc.wrappedValue.source == "token" {
                            SecureField("", text: acc.argument)
                        } else {
                            TextField("", text: acc.argument)
                        }
                    }
                }
                HStack {
                    Text("Резерв").frame(width: 70, alignment: .leading)
                    Text("5ч").foregroundColor(.secondary)
                    TextField("как общий", text: acc.reserve5).frame(width: 70)
                    Text("7д").foregroundColor(.secondary)
                    TextField("как общий", text: acc.reserve7).frame(width: 70)
                }
                Divider()
                diagnostics(d)
            }
            .padding(6)
            .opacity(acc.wrappedValue.hidden ? 0.55 : 1)
        }
    }

    @ViewBuilder
    private func diagnostics(_ d: DiagAccount?) -> some View {
        if let d {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 14) {
                    label("отпечаток", d.fingerprint ?? "нет")
                    label("scope", d.scope_ok == nil ? "не проверялся"
                          : (d.scope_ok == true ? "есть" : "нет user:profile"))
                    label("кэш", d.cache_age.map { fmtDur($0) + " назад" } ?? "пусто")
                }
                if let err = d.token_error {
                    Text(err).font(.caption).foregroundColor(.red)
                }
                if d.scope_ok == false {
                    Text("Этот токен лимиты не отдаёт. Scope user:profile даёт вход через /login; claude setup-token - нет.")
                        .font(.caption).foregroundColor(.orange)
                }
                if let t = d.throttle_left, t > 0 {
                    Text("пауза после 429: ещё \(fmtDur(t))")
                        .font(.caption).foregroundColor(.orange)
                }
            }
        } else {
            Text("диагностики нет - сохрани конфиг и нажми «Проверить токены»")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func label(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k + ":").font(.caption).foregroundColor(.secondary)
            Text(v).font(.caption.monospaced())
        }
    }

    // --- индикатор

    private var barTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Что показывают кольца") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Аккаунт на иконке", selection: Binding(
                        get: { prefs.account ?? "" },
                        set: { prefs.account = $0.isEmpty ? nil : $0; prefs.save() })) {
                        Text("первый, у кого есть данные").tag("")
                        ForEach(store.accounts.map(\.name), id: \.self) { Text($0).tag($0) }
                    }
                    Text("Меню всё равно показывает все аккаунты.")
                        .font(.caption).foregroundColor(.secondary)
                }.padding(6)
            }

            GroupBox("Опрос") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Раз в")
                        Stepper(value: Binding(
                            get: { prefs.pollInterval },
                            set: { prefs.pollInterval = $0; prefs.save() }),
                                in: 10...600, step: 10) {
                            Text("\(Int(prefs.pollInterval)) с").monospacedDigit()
                        }.frame(width: 160)
                    }
                    Text("Читается кэш, в сеть индикатор не ходит: обновление идёт фоном, как у статуслайна.")
                        .font(.caption).foregroundColor(.secondary)
                }.padding(6)
            }

            GroupBox("Автозапуск") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Запускать при входе в систему", isOn: Binding(
                        get: { autostart },
                        set: { on in
                            do {
                                if on { try LaunchAgent.install() } else { try LaunchAgent.uninstall() }
                                autostart = on
                                autostartNote = on && !LaunchAgent.managedByLaunchd
                                    ? "Агент записан, подхватится при следующем входе."
                                    : nil
                            } catch {
                                autostartNote = "не вышло: \(error.localizedDescription)"
                            }
                        }))
                    Text(LaunchAgent.plistPath).font(.caption.monospaced()).foregroundColor(.secondary)
                    if let n = autostartNote {
                        Text(n).font(.caption).foregroundColor(.orange)
                    }
                }.padding(6)
            }
            Spacer()
        }.padding(16)
    }

    // --- низ окна

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let e = store.error { banner(e, color: .red) }
            if let n = store.note { banner(n, color: .green) }
            HStack {
                Text(store.configPath).font(.caption.monospaced()).foregroundColor(.secondary)
                Spacer()
                Button("Перечитать") { store.load(); store.refreshDiagnose() }
                Button("Сохранить") { store.save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(12)
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.15))
            .cornerRadius(6)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store = ConfigStore()

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Лимиты Claude Code"
        window.center()
        self.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
        window.delegate = self
    }

    func show() {
        store.load()
        store.refreshDiagnose()
        // accessory-приложение окон само не поднимает: без активации окно
        // откроется под чужими и будет выглядеть как будто ничего не произошло
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
