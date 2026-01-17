import Foundation

/// Режим воспроизведения плейлиста
public enum PlaybackMode {
    case sequential  // По порядку
    case shuffle     // Случайный порядок
    case repeatOne   // Повторять один трек
}

/// Делегат плейлиста для получения уведомлений
public protocol PlaylistDelegate: AnyObject {
    func playlist(_ playlist: Playlist, willPlayTrack track: String)
    func playlist(_ playlist: Playlist, didFinishTrack track: String)
    func playlist(_ playlist: Playlist, didEncounterError error: Error, forTrack track: String)
    func playlistDidFinish(_ playlist: Playlist)
}

/// Менеджер плейлиста - следит за папкой и управляет очередью треков
public final class Playlist {

    /// Путь к папке с музыкой
    public let directory: URL

    /// Режим воспроизведения
    public var playbackMode: PlaybackMode = .sequential

    /// Делегат
    public weak var delegate: PlaylistDelegate?

    /// Текущий список треков
    public private(set) var tracks: [String] = []

    /// Индекс текущего трека
    public private(set) var currentIndex: Int = 0

    /// Текущий трек
    public var currentTrack: String? {
        guard currentIndex >= 0 && currentIndex < tracks.count else { return nil }
        return tracks[currentIndex]
    }

    private var directoryMonitor: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.pirateradio.playlist")

    public init(directory: URL) {
        self.directory = directory
    }

    deinit {
        stopMonitoring()
    }

    /// Сканировать директорию и загрузить треки
    public func scan() throws {
        let fm = FileManager.default

        guard fm.fileExists(atPath: directory.path) else {
            throw PlaylistError.directoryNotFound(directory.path)
        }

        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        tracks = contents
            .filter { AudioConverter.isSupported($0.path) }
            .map { $0.path }
            .sorted()

        if playbackMode == .shuffle {
            tracks.shuffle()
        }

        currentIndex = 0
    }

    /// Получить следующий трек
    public func nextTrack() -> String? {
        guard !tracks.isEmpty else { return nil }

        switch playbackMode {
        case .sequential:
            currentIndex += 1
            if currentIndex >= tracks.count {
                currentIndex = 0
            }
        case .shuffle:
            currentIndex = Int.random(in: 0..<tracks.count)
        case .repeatOne:
            // Оставляем тот же индекс
            break
        }

        return currentTrack
    }

    /// Получить предыдущий трек
    public func previousTrack() -> String? {
        guard !tracks.isEmpty else { return nil }

        currentIndex -= 1
        if currentIndex < 0 {
            currentIndex = tracks.count - 1
        }

        return currentTrack
    }

    /// Добавить трек в плейлист
    public func addTrack(_ path: String) {
        guard AudioConverter.isSupported(path) else { return }
        tracks.append(path)
    }

    /// Удалить трек из плейлиста
    public func removeTrack(at index: Int) {
        guard index >= 0 && index < tracks.count else { return }
        tracks.remove(at: index)
        if currentIndex >= tracks.count {
            currentIndex = max(0, tracks.count - 1)
        }
    }

    /// Начать мониторинг папки на изменения
    public func startMonitoring() {
        stopMonitoring()

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        directoryMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )

        directoryMonitor?.setEventHandler { [weak self] in
            try? self?.scan()
        }

        directoryMonitor?.setCancelHandler {
            close(fd)
        }

        directoryMonitor?.resume()
    }

    /// Остановить мониторинг
    public func stopMonitoring() {
        directoryMonitor?.cancel()
        directoryMonitor = nil
    }
}

/// Ошибки плейлиста
public enum PlaylistError: Error, LocalizedError {
    case directoryNotFound(String)
    case noTracksFound

    public var errorDescription: String? {
        switch self {
        case .directoryNotFound(let path):
            return "Директория не найдена: \(path)"
        case .noTracksFound:
            return "В папке нет поддерживаемых аудио файлов"
        }
    }
}
