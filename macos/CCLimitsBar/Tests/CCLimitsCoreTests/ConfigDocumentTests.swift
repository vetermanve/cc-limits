import XCTest
@testable import CCLimitsCore

final class ConfigDocumentTests: XCTestCase {

    private func parse(_ json: String) -> ConfigDocument.Parsed {
        ConfigDocument.parse(Data(json.utf8))
    }

    private func dict(_ p: ConfigDocument.Parsed) -> [String: Any] {
        ConfigDocument.serialize(p)
    }

    func testНеизвестныеКлючиВыживают() {
        var p = parse("""
        {"notes": "не трогай", "reserve": {"five_hour": 20},
         "accounts": [{"name": "личный", "source": "keychain", "future_flag": 42}]}
        """)
        p.accounts[0].name = "переименован"
        let out = dict(p)

        XCTAssertEqual(out["notes"] as? String, "не трогай")
        let acc = (out["accounts"] as? [[String: Any]])?.first
        XCTAssertEqual(acc?["future_flag"] as? Int, 42)
        XCTAssertEqual(acc?["name"] as? String, "переименован")
    }

    func testСкрытиеИВозврат() {
        var p = parse("""
        {"accounts": [{"name": "флот", "source": "command", "command": "cat /t"}]}
        """)
        XCTAssertFalse(p.accounts[0].hidden)

        p.accounts[0].hidden = true
        var acc = (dict(p)["accounts"] as? [[String: Any]])?.first
        XCTAssertEqual(acc?["hidden"] as? Bool, true)
        // команда получения токена при скрытии не теряется
        XCTAssertEqual(acc?["command"] as? String, "cat /t")

        p.accounts[0].hidden = false
        acc = (dict(p)["accounts"] as? [[String: Any]])?.first
        XCTAssertNil(acc?["hidden"], "false пишем отсутствием ключа, а не hidden: false")
    }

    func testСменаИсточникаУбираетЧужойАргумент() {
        var p = parse("""
        {"accounts": [{"name": "a", "source": "command", "command": "cat /t"}]}
        """)
        XCTAssertEqual(p.accounts[0].argument, "cat /t")

        p.accounts[0].source = "file"
        p.accounts[0].argument = "/tmp/token"
        let acc = (dict(p)["accounts"] as? [[String: Any]])?.first
        XCTAssertEqual(acc?["path"] as? String, "/tmp/token")
        XCTAssertNil(acc?["command"], "старый аргумент источника должен уйти")
    }

    func testИсточникиБезАргумента() {
        var p = parse("""
        {"accounts": [{"name": "a", "source": "env", "var": "TOKEN_X"}]}
        """)
        p.accounts[0].source = "keychain"
        let acc = (dict(p)["accounts"] as? [[String: Any]])?.first
        XCTAssertEqual(acc?["source"] as? String, "keychain")
        for k in ["var", "path", "command", "token"] {
            XCTAssertNil(acc?[k], "у keychain не должно остаться \(k)")
        }
    }

    func testПустойРезервУбираетКлюч() {
        var p = parse("""
        {"reserve": {"five_hour": 20, "seven_day": 5},
         "accounts": [{"name": "a", "source": "auto", "reserve": {"five_hour": 50}}]}
        """)
        XCTAssertEqual(p.reserve5, "20")
        XCTAssertEqual(p.accounts[0].reserve5, "50")

        p.reserve5 = ""
        p.reserve7 = ""
        p.accounts[0].reserve5 = ""
        let out = dict(p)
        XCTAssertNil(out["reserve"], "пустые поля резерва не должны оставлять пустой объект")
        XCTAssertNil((out["accounts"] as? [[String: Any]])?.first?["reserve"])
    }

    func testДробныйРезервНеОкругляется() {
        var p = parse(#"{"accounts": [{"name": "a", "source": "auto"}]}"#)
        p.reserve5 = "12.5"
        let res = dict(p)["reserve"] as? [String: Any]
        XCTAssertEqual(res?["five_hour"] as? Double, 12.5)
    }

    func testМусорВРезервеДоезжаетДоПроверки() {
        var p = parse(#"{"accounts": [{"name": "a", "source": "auto"}]}"#)
        p.reserve5 = "много"
        let res = dict(p)["reserve"] as? [String: Any]
        XCTAssertEqual(res?["five_hour"] as? String, "много",
                       "мусор нельзя глотать молча: его должен отвергнуть --check-config")
    }

    func testПустойФайлНеПадает() {
        let p = ConfigDocument.parse(nil)
        XCTAssertTrue(p.accounts.isEmpty)
        XCTAssertTrue(ConfigDocument.serialize(p).isEmpty)
    }

    func testУдалениеПоследнегоАккаунтаУбираетСписок() {
        var p = parse(#"{"accounts": [{"name": "a", "source": "auto"}], "reserve": {"five_hour": 1}}"#)
        p.accounts.removeAll()
        let out = dict(p)
        XCTAssertNil(out["accounts"])
        XCTAssertNotNil(out["reserve"], "резерв не должен исчезать вместе с аккаунтами")
    }

    func testКириллицаНеЭкранируется() throws {
        var p = parse(#"{"accounts": [{"name": "a", "source": "auto"}]}"#)
        p.accounts[0].name = "личный"
        let text = String(data: try ConfigDocument.jsonData(p), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("личный"), "в файле должна быть кириллица, а не \\u-экранирование")
    }
}
