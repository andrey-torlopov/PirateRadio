import Foundation

/// Конвертер аудио файлов в WAV формат через ffmpeg
public struct AudioConverter {

    /// Поддерживаемые форматы
    public static let supportedExtensions = ["mp3", "wav", "flac", "ogg", "m4a", "aac", "wma"]

    /// Проверить, поддерживается ли формат файла
    public static func isSupported(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// Проверить, является ли файл уже WAV с нужными параметрами
    public static func isCompatibleWAV(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "wav"
    }

    /// Конвертировать аудио файл в WAV и записать в stdout через pipe
    /// Возвращает Process, который пишет PCM данные в stdout
    public static func createConversionProcess(
        inputPath: String,
        sampleRate: Int = 22050,
        channels: Int = 1
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ffmpeg")
        process.arguments = [
            "-i", inputPath,
            "-f", "wav",
            "-acodec", "pcm_s16le",
            "-ar", "\(sampleRate)",
            "-ac", "\(channels)",
            "-"  // Выход в stdout
        ]
        // Подавляем stderr от ffmpeg
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Создать процесс для конкатенации нескольких файлов в единый WAV поток
    public static func createConcatProcess(
        inputPaths: [String],
        sampleRate: Int = 22050,
        channels: Int = 1
    ) throws -> Process {
        // Создаём временный файл со списком входных файлов
        let listContent = inputPaths.map { "file '\($0)'" }.joined(separator: "\n")
        let tempDir = FileManager.default.temporaryDirectory
        let listFile = tempDir.appendingPathComponent("ffmpeg_concat_\(UUID().uuidString).txt")
        try listContent.write(to: listFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ffmpeg")
        process.arguments = [
            "-f", "concat",
            "-safe", "0",
            "-i", listFile.path,
            "-f", "wav",
            "-acodec", "pcm_s16le",
            "-ar", "\(sampleRate)",
            "-ac", "\(channels)",
            "-"
        ]
        process.standardError = FileHandle.nullDevice

        // Удалить временный файл после завершения
        process.terminationHandler = { _ in
            try? FileManager.default.removeItem(at: listFile)
        }

        return process
    }
}
