import Foundation
import CFMTransmitter

/// Ошибки FM-передатчика
public enum FMTransmitterError: Error, LocalizedError {
    case initFailed
    case fileNotFound(String)
    case invalidFormat
    case transmissionFailed(String)
    case permissionDenied
    case alreadyRunning
    case notRunning
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .initFailed:
            return "Не удалось инициализировать передатчик"
        case .fileNotFound(let path):
            return "Файл не найден: \(path)"
        case .invalidFormat:
            return "Неподдерживаемый формат аудио"
        case .transmissionFailed(let reason):
            return "Ошибка передачи: \(reason)"
        case .permissionDenied:
            return "Недостаточно прав. Запустите с sudo"
        case .alreadyRunning:
            return "Передатчик уже работает"
        case .notRunning:
            return "Передатчик не запущен"
        case .unknown(let message):
            return "Неизвестная ошибка: \(message)"
        }
    }

    fileprivate init(code: FMTransmitterErrorCode, handle: FMTransmitterRef?) {
        switch code {
        case .success:
            self = .unknown("Success is not an error")
        case .initFailed:
            self = .initFailed
        case .fileNotFound:
            self = .fileNotFound("")
        case .invalidFormat:
            self = .invalidFormat
        case .transmissionFailed:
            let msg = handle.flatMap { fm_transmitter_get_error($0).map { String(cString: $0) } } ?? "Unknown"
            self = .transmissionFailed(msg)
        case .permissionDenied:
            self = .permissionDenied
        case .alreadyRunning:
            self = .alreadyRunning
        case .notRunning:
            self = .notRunning
        @unknown default:
            self = .unknown("Code: \(code.rawValue)")
        }
    }
}

/// Код ошибки для внутреннего использования
private enum FMTransmitterErrorCode: Int32 {
    case success = 0
    case initFailed = -1
    case fileNotFound = -2
    case invalidFormat = -3
    case transmissionFailed = -4
    case permissionDenied = -5
    case alreadyRunning = -6
    case notRunning = -7
}

/// Конфигурация FM-передатчика
public struct FMTransmitterConfiguration {
    /// Частота вещания в MHz (87.5 - 108.0)
    public var frequency: Float

    /// Ширина полосы в kHz (по умолчанию 200)
    public var bandwidth: Float

    /// DMA канал (0-15)
    public var dmaChannel: UInt16

    /// Повторять воспроизведение
    public var loop: Bool

    public init(
        frequency: Float = 100.0,
        bandwidth: Float = 200.0,
        dmaChannel: UInt16 = 0,
        loop: Bool = false
    ) {
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.dmaChannel = dmaChannel
        self.loop = loop
    }

    var cConfig: FMTransmitterConfig {
        var config = fm_transmitter_default_config()
        config.frequency = frequency
        config.bandwidth = bandwidth
        config.dmaChannel = dmaChannel
        config.loop = loop
        return config
    }
}

/// FM-передатчик для Raspberry Pi
public final class FMTransmitter {
    private var handle: FMTransmitterRef?

    public init() throws {
        handle = fm_transmitter_create()
        guard handle != nil else {
            throw FMTransmitterError.initFailed
        }
    }

    deinit {
        if let handle = handle {
            fm_transmitter_destroy(handle)
        }
    }

    /// Запустить передачу WAV-файла
    public func transmit(file path: String, config: FMTransmitterConfiguration = .init()) throws {
        guard let handle = handle else {
            throw FMTransmitterError.initFailed
        }

        var cConfig = config.cConfig
        let result = fm_transmitter_start_file(handle, path, &cConfig)

        if result.rawValue != 0 {
            let code = FMTransmitterErrorCode(rawValue: result.rawValue) ?? .initFailed
            throw FMTransmitterError(code: code, handle: handle)
        }
    }

    /// Запустить передачу из stdin (для пайпа аудио)
    public func transmitFromStdin(config: FMTransmitterConfiguration = .init()) throws {
        guard let handle = handle else {
            throw FMTransmitterError.initFailed
        }

        var cConfig = config.cConfig
        let result = fm_transmitter_start_stdin(handle, &cConfig)

        if result.rawValue != 0 {
            let code = FMTransmitterErrorCode(rawValue: result.rawValue) ?? .initFailed
            throw FMTransmitterError(code: code, handle: handle)
        }
    }

    /// Остановить передачу
    public func stop() {
        guard let handle = handle else { return }
        fm_transmitter_stop(handle)
    }

    /// Проверить, идёт ли передача
    public var isRunning: Bool {
        guard let handle = handle else { return false }
        return fm_transmitter_is_running(handle)
    }

    /// Получить последнюю ошибку
    public var lastError: String? {
        guard let handle = handle,
              let cStr = fm_transmitter_get_error(handle) else {
            return nil
        }
        return String(cString: cStr)
    }
}
