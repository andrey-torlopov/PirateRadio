import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Делегат радиостанции
public protocol RadioStationDelegate: AnyObject {
    func radioStation(_ station: RadioStation, didStartPlaying track: String)
    func radioStation(_ station: RadioStation, didFinishPlaying track: String)
    func radioStation(_ station: RadioStation, didEncounterError error: Error)
    func radioStationDidStop(_ station: RadioStation)
}

/// Радиостанция - объединяет плейлист, конвертацию и FM-передачу
public final class RadioStation {

    /// Частота вещания (MHz)
    public var frequency: Float {
        didSet { config.frequency = frequency }
    }

    /// Плейлист
    public let playlist: Playlist

    /// Делегат
    public weak var delegate: RadioStationDelegate?

    /// Идёт ли вещание
    public private(set) var isBroadcasting: Bool = false

    private var config: FMTransmitterConfiguration
    private var currentProcess: Process?
    private var currentTransmitter: FMTransmitter?
    private let queue = DispatchQueue(label: "com.pirateradio.station")
    private var shouldStop = false

    public init(directory: URL, frequency: Float = 100.0) {
        self.frequency = frequency
        self.playlist = Playlist(directory: directory)
        self.config = FMTransmitterConfiguration(frequency: frequency)
    }

    /// Запустить вещание
    public func start() throws {
        guard !isBroadcasting else { return }

        try playlist.scan()

        guard !playlist.tracks.isEmpty else {
            throw PlaylistError.noTracksFound
        }

        shouldStop = false
        isBroadcasting = true
        playlist.startMonitoring()

        queue.async { [weak self] in
            self?.broadcastLoop()
        }
    }

    /// Остановить вещание
    public func stop() {
        shouldStop = true
        currentProcess?.terminate()
        currentTransmitter?.stop()
        playlist.stopMonitoring()
        isBroadcasting = false

        delegate?.radioStationDidStop(self)
    }

    /// Следующий трек
    public func nextTrack() {
        currentProcess?.terminate()
        currentTransmitter?.stop()
        _ = playlist.nextTrack()
    }

    /// Предыдущий трек
    public func previousTrack() {
        currentProcess?.terminate()
        currentTransmitter?.stop()
        _ = playlist.previousTrack()
    }

    // MARK: - Private

    private func broadcastLoop() {
        while !shouldStop {
            guard let trackPath = playlist.currentTrack else {
                // Пересканируем плейлист
                do {
                    try playlist.scan()
                    if playlist.tracks.isEmpty {
                        Thread.sleep(forTimeInterval: 5.0)
                        continue
                    }
                } catch {
                    notifyError(error)
                    Thread.sleep(forTimeInterval: 5.0)
                    continue
                }
                continue
            }

            let trackName = (trackPath as NSString).lastPathComponent
            do {
                try playTrack(trackPath, trackName: trackName)
                notifyFinished(trackName)
            } catch {
                notifyError(error)
            }

            // Переход к следующему треку
            _ = playlist.nextTrack()
        }
    }

    private func playTrack(_ path: String, trackName: String) throws {
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pirate-radio-\(UUID().uuidString).converted.wav")
        let wavPath = wavURL.path
        defer {
            currentProcess = nil
            currentTransmitter?.stop()
            currentTransmitter = nil
            try? FileManager.default.removeItem(atPath: wavPath)
        }

        let ffmpeg = AudioConverter.createFileConversionProcess(inputPath: path, outputPath: wavPath)
        let errorPipe = Pipe()
        ffmpeg.standardError = errorPipe
        currentProcess = ffmpeg

        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        currentProcess = nil

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if shouldStop {
            return
        }

        guard ffmpeg.terminationStatus == 0 else {
            throw RadioStationError.conversionFailed(path, errorOutput)
        }

        let transmitter = try FMTransmitter()
        currentTransmitter = transmitter
        try transmitter.transmit(file: wavPath, config: config)
        notifyStarted(trackName)

        while transmitter.isRunning && !shouldStop {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if let lastError = transmitter.lastError, !shouldStop {
            throw RadioStationError.transmissionFailed(lastError)
        }
    }

    private func notifyStarted(_ track: String) {
        delegate?.radioStation(self, didStartPlaying: track)
    }

    private func notifyFinished(_ track: String) {
        delegate?.radioStation(self, didFinishPlaying: track)
    }

    private func notifyError(_ error: Error) {
        delegate?.radioStation(self, didEncounterError: error)
    }
}

/// Ошибки радиостанции
public enum RadioStationError: Error, LocalizedError {
    case conversionFailed(String, String)
    case transmissionFailed(String)
    case audioPipeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .conversionFailed(let path, let reason):
            if reason.isEmpty {
                return "Не удалось конвертировать файл: \(path)"
            }
            return "Не удалось конвертировать файл: \(path). \(reason)"
        case .transmissionFailed(let reason):
            return "Ошибка FM-передатчика: \(reason)"
        case .audioPipeFailed(let reason):
            return "Не удалось создать аудио-пайп: \(reason)"
        }
    }
}
