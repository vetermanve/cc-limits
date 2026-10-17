// Разбор и сборка $CLAUDE_CONFIG_DIR/cc-limits.json для окна настроек.
//
// Главное требование: запись не должна терять то, чего окно не знает.
// Конфиг редактируют и руками, и будущие версии CLI могут завести новые
// ключи; молча выкусить их при сохранении - потерять чужую работу. Поэтому
// исходный словарь сохраняется целиком, а правятся только знакомые поля.

import Foundation

public struct AccountRow: Identifiable {
    public let id: UUID
    public var name: String
    public var source: String
    /// значение аргумента источника: var / path / command / token
    public var argument: String
    public var reserve5: String
    public var reserve7: String
    /// скрытый аккаунт остаётся в конфиге целиком, но уходит из индикатора,
    /// статуслайна и обычного вывода CLI
    public var hidden: Bool
    /// неизвестные нам ключи этого аккаунта, переносятся в файл как есть
    public var extra: [String: Any]

    public init(id: UUID = UUID(), name: String = "", source: String = "keychain",
                argument: String = "", reserve5: String = "", reserve7: String = "",
                hidden: Bool = false, extra: [String: Any] = [:]) {
        self.id = id
        self.name = name
        self.source = source
        self.argument = argument
        self.reserve5 = reserve5
        self.reserve7 = reserve7
        self.hidden = hidden
        self.extra = extra
    }
}

public let ACCOUNT_SOURCES = ["auto", "keychain", "credentials", "env", "file",
                              "command", "token"]

/// Ключ, в котором источник держит свой аргумент. nil - источник без аргумента.
public func argumentKey(for source: String) -> String? {
    switch source {
    case "env": return "var"
    case "file": return "path"
    case "command": return "command"
    case "token": return "token"
    default: return nil
    }
}

public enum ConfigDocument {
    public struct Parsed {
        public var raw: [String: Any]
        public var reserve5: String
        public var reserve7: String
        public var accounts: [AccountRow]

        public init(raw: [String: Any] = [:], reserve5: String = "",
                    reserve7: String = "", accounts: [AccountRow] = []) {
            self.raw = raw
            self.reserve5 = reserve5
            self.reserve7 = reserve7
            self.accounts = accounts
        }
    }

    private static let managedAccountKeys = ["name", "source", "var", "path",
                                             "command", "token", "reserve", "hidden"]

    public static func parse(_ data: Data?) -> Parsed {
        var raw: [String: Any] = [:]
        if let data, !data.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = obj
        }
        let res = raw["reserve"] as? [String: Any] ?? [:]
        let accounts = (raw["accounts"] as? [[String: Any]] ?? []).map { d -> AccountRow in
            var extra = d
            for k in managedAccountKeys { extra.removeValue(forKey: k) }
            let r = d["reserve"] as? [String: Any] ?? [:]
            let source = d["source"] as? String ?? "auto"
            let argument = argumentKey(for: source).flatMap { d[$0] as? String } ?? ""
            return AccountRow(
                name: d["name"] as? String ?? "",
                source: source,
                argument: argument,
                reserve5: numString(r["five_hour"]),
                reserve7: numString(r["seven_day"]),
                hidden: d["hidden"] as? Bool ?? false,
                extra: extra)
        }
        return Parsed(raw: raw,
                      reserve5: numString(res["five_hour"]),
                      reserve7: numString(res["seven_day"]),
                      accounts: accounts)
    }

    public static func serialize(_ p: Parsed) -> [String: Any] {
        var out = p.raw

        var res = p.raw["reserve"] as? [String: Any] ?? [:]
        setNum(&res, "five_hour", p.reserve5)
        setNum(&res, "seven_day", p.reserve7)
        if res.isEmpty { out.removeValue(forKey: "reserve") } else { out["reserve"] = res }

        if p.accounts.isEmpty {
            out.removeValue(forKey: "accounts")
        } else {
            out["accounts"] = p.accounts.map { a -> [String: Any] in
                var d = a.extra
                d["name"] = a.name
                d["source"] = a.source
                // старый аргумент убираем всегда: при смене источника
                // оставшийся "command" рядом с source=keychain вводил бы в
                // заблуждение и того, кто читает файл, и будущие версии CLI
                for k in ["var", "path", "command", "token"] { d.removeValue(forKey: k) }
                if let key = argumentKey(for: a.source), !a.argument.isEmpty {
                    d[key] = a.argument
                }
                var r: [String: Any] = [:]
                setNum(&r, "five_hour", a.reserve5)
                setNum(&r, "seven_day", a.reserve7)
                if r.isEmpty { d.removeValue(forKey: "reserve") } else { d["reserve"] = r }
                if a.hidden { d["hidden"] = true } else { d.removeValue(forKey: "hidden") }
                return d
            }
        }
        return out
    }

    public static func jsonData(_ p: Parsed) throws -> Data {
        try JSONSerialization.data(withJSONObject: serialize(p),
                                   options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    static func numString(_ v: Any?) -> String {
        guard let n = v as? NSNumber else { return "" }
        let d = n.doubleValue
        return d == d.rounded() ? String(Int(d)) : String(d)
    }

    static func setNum(_ dict: inout [String: Any], _ key: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            dict.removeValue(forKey: key)
        } else if let d = Double(t.replacingOccurrences(of: ",", with: ".")) {
            dict[key] = d == d.rounded() ? Int(d) as Any : d as Any
        } else {
            // мусор не глотаем молча: пусть до него доберётся --check-config
            // и скажет человеку, что именно не так
            dict[key] = t
        }
    }
}
