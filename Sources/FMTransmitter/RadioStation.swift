import Foundation

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
    private var fmProcess: Process?
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
        fmProcess?.terminate()
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
        _ = playlist.nextTrack()
    }

    /// Предыдущий трек
    public func previousTrack() {
        currentProcess?.terminate()
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
        // Создаём пайп: ffmpeg -> fm_transmitter
        let ffmpeg = AudioConverter.createConversionProcess(inputPath: path)
        let pipe = Pipe()
        ffmpeg.standardOutput = pipe

        // fm_transmitter читает из stdin
        let fmTransmitter = Process()
        fmTransmitter.executableURL = URL(fileURLWithPath: "/usr/local/bin/fm_transmitter")
        fmTransmitter.arguments = [
            "-f", String(format: "%.1f", frequency),
            "-"
        ]
        fmTransmitter.standardInput = pipe
        fmTransmitter.standardOutput = FileHandle.nullDevice
        fmTransmitter.standardError = FileHandle.nullDevice

        currentProcess = ffmpeg
        fmProcess = fmTransmitter

        try ffmpeg.run()
        try fmTransmitter.run()

        // Ждём завершения ffmpeg (он закончит когда файл прочитан)
        ffmpeg.waitUntilExit()

        // Даём fm_transmitter время допроиграть буфер
        Thread.sleep(forTimeInterval: 0.5)
        fmTransmitter.terminate()

        currentProcess = nil
        fmProcess = nil

        if ffmpeg.terminationStatus != 0 && !shouldStop {
            throw RadioStationError.conversionFailed(path)
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
    case transmitterNotFound

    public var errorDescription: String? {
        switch self {
        case .conversionFailed(let path):
            return "Не удалось конвертировать файл: \(path)"
        case .transmitterNotFound:
            return "fm_transmitter не найден. Установите его в /usr/local/bin/"
        }
    }
}
