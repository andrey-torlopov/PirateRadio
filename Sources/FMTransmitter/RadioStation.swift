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
    private var currentPipeWriter: FileHandle?
    private var currentPipePath: String?
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
        currentPipeWriter?.closeFile()
        currentPipeWriter = nil
        currentTransmitter?.stop()
        if let currentPipePath {
            try? FileManager.default.removeItem(atPath: currentPipePath)
        }
        playlist.stopMonitoring()
        isBroadcasting = false

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.radioStationDidStop(self)
        }
    }

    /// Следующий трек
    public func nextTrack() {
        currentProcess?.terminate()
        currentPipeWriter?.closeFile()
        currentPipeWriter = nil
        currentTransmitter?.stop()
        _ = playlist.nextTrack()
    }

    /// Предыдущий трек
    public func previousTrack() {
        currentProcess?.terminate()
        currentPipeWriter?.closeFile()
        currentPipeWriter = nil
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
            notifyStarted(trackName)

            do {
                try playTrack(trackPath)
                notifyFinished(trackName)
            } catch {
                notifyError(error)
            }

            // Переход к следующему треку
            _ = playlist.nextTrack()
        }
    }

    private func playTrack(_ path: String) throws {
        let fifoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pirate-radio-\(UUID().uuidString).wav")
        let fifoPath = fifoURL.path

        guard mkfifo(fifoPath, S_IRUSR | S_IWUSR) == 0 else {
            throw RadioStationError.audioPipeFailed(String(cString: strerror(errno)))
        }

        currentPipePath = fifoPath
        defer {
            currentProcess = nil
            currentPipeWriter?.closeFile()
            currentPipeWriter = nil
            currentTransmitter?.stop()
            currentTransmitter = nil
            try? FileManager.default.removeItem(atPath: fifoPath)
            currentPipePath = nil
        }

        let transmitter = try FMTransmitter()
        currentTransmitter = transmitter
        try transmitter.transmit(file: fifoPath, config: config)

        guard let pipeWriter = FileHandle(forWritingAtPath: fifoPath) else {
            throw RadioStationError.audioPipeFailed("Не удалось открыть FIFO для записи: \(fifoPath)")
        }
        currentPipeWriter = pipeWriter

        let ffmpeg = AudioConverter.createConversionProcess(inputPath: path)
        ffmpeg.standardOutput = pipeWriter

        currentProcess = ffmpeg

        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        if currentPipeWriter === pipeWriter {
            pipeWriter.closeFile()
            currentPipeWriter = nil
        }

        while transmitter.isRunning && !shouldStop {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if ffmpeg.terminationStatus != 0 && !shouldStop {
            throw RadioStationError.conversionFailed(path)
        }

        if let lastError = transmitter.lastError, !shouldStop {
            throw RadioStationError.transmissionFailed(lastError)
        }
    }

    private func notifyStarted(_ track: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.radioStation(self, didStartPlaying: track)
        }
    }

    private func notifyFinished(_ track: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.radioStation(self, didFinishPlaying: track)
        }
    }

    private func notifyError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.radioStation(self, didEncounterError: error)
        }
    }
}

/// Ошибки радиостанции
public enum RadioStationError: Error, LocalizedError {
    case conversionFailed(String)
    case transmissionFailed(String)
    case audioPipeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .conversionFailed(let path):
            return "Не удалось конвертировать файл: \(path)"
        case .transmissionFailed(let reason):
            return "Ошибка FM-передатчика: \(reason)"
        case .audioPipeFailed(let reason):
            return "Не удалось создать аудио-пайп: \(reason)"
        }
    }
}
