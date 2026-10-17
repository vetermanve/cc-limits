// Запись конфига через внешнюю проверку.
//
// Окно настроек никогда не пишет рабочий файл напрямую: сначала кандидат
// уходит во временный файл, его читает тот же код, что читает рабочий конфиг
// (`cc-limits --check-config`), и только при нулевом коде возврата файл
// подменяется атомарно. Битая форма до диска не доезжает.

import Foundation

public enum ConfigWriter {
    /// Проверка кандидата по пути. Нулевой код - годен.
    public typealias Validator = (_ candidatePath: String) -> (code: Int32, message: String)

    /// Возвращает nil при успехе либо причину, по которой запись не состоялась.
    public static func write(_ data: Data, to path: String,
                             validate: Validator) -> String? {
        let tmp = NSTemporaryDirectory()
            + "cc-limits-candidate-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        do {
            try data.write(to: URL(fileURLWithPath: tmp))
        } catch {
            return "не записал временный файл: \(error.localizedDescription)"
        }

        let verdict = validate(tmp)
        guard verdict.code == 0 else {
            let msg = verdict.message.trimmingCharacters(in: .whitespacesAndNewlines)
            // пустое сообщение валидатора оставило бы человека без причины
            return msg.isEmpty ? "конфиг не прошёл проверку" : msg
        }

        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return "не записал \(path): \(error.localizedDescription)"
        }
        return nil
    }
}
