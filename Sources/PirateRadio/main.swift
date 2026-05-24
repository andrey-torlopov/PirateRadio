import Foundation
import FMTransmitter

// MARK: - CLI Arguments

struct Arguments {
    var directory: String = "./music"
    var frequency: Float = 100.0
    var dmaChannel: UInt16 = 0xff
    var shuffle: Bool = false
    var showHelp: Bool = false
    var showVersion: Bool = false
}

func parseArguments() -> Arguments {
    var args = Arguments()
    var i = 1
    let argv = CommandLine.arguments

    while i < argv.count {
        switch argv[i] {
        case "-d", "--directory":
            i += 1
            if i < argv.count {
                args.directory = argv[i]
            }
        case "-f", "--frequency":
            i += 1
            if i < argv.count {
                args.frequency = Float(argv[i]) ?? 100.0
            }
        case "-s", "--shuffle":
            args.shuffle = true
        case "--dma-channel":
            i += 1
            if i < argv.count {
                let value = argv[i].lowercased()
                if value == "cpu" {
                    args.dmaChannel = 0xff
                } else if let channel = UInt16(value), channel <= 15 {
                    args.dmaChannel = channel
                }
            }
        case "-h", "--help":
            args.showHelp = true
        case "-v", "--version":
            args.showVersion = true
        default:
            // Позиционный аргумент - директория
            if !argv[i].hasPrefix("-") {
                args.directory = argv[i]
            }
        }
        i += 1
    }

    return args
}

func printHelp() {
    print("""
    PirateRadio - FM радиостанция на Raspberry Pi

    Использование:
      pirate-radio [OPTIONS] [DIRECTORY]

    Опции:
      -d, --directory PATH   Папка с музыкой (по умолчанию: ./music)
      -f, --frequency MHz    Частота вещания (по умолчанию: 100.0)
      --dma-channel VALUE    DMA канал 0-15 или cpu (по умолчанию: cpu)
      -s, --shuffle          Случайный порядок треков
      -h, --help             Показать эту справку
      -v, --version          Показать версию

    Примеры:
      sudo pirate-radio -f 88.5 ~/Music
      sudo pirate-radio --shuffle -f 100.0 /home/pi/radio

    Поддерживаемые форматы: mp3, wav, flac, ogg, m4a, aac

    Управление во время работы:
      n - следующий трек
      p - предыдущий трек
      s - переключить shuffle
      q - выход

    ВАЖНО: Требуется запуск с sudo для доступа к GPIO.
    """)
}

func printVersion() {
    print("PirateRadio v0.1.0")
}

// MARK: - Radio Delegate

final class RadioDelegate: RadioStationDelegate {
    func radioStation(_ station: RadioStation, didStartPlaying track: String) {
        print("▶ Играет: \(track)")
    }

    func radioStation(_ station: RadioStation, didFinishPlaying track: String) {
        // Тихо переходим к следующему
    }

    func radioStation(_ station: RadioStation, didEncounterError error: Error) {
        print("⚠ Ошибка: \(error.localizedDescription)")
    }

    func radioStationDidStop(_ station: RadioStation) {
        print("⏹ Вещание остановлено")
    }
}

// MARK: - Main

let args = parseArguments()

if args.showHelp {
    printHelp()
    exit(0)
}

if args.showVersion {
    printVersion()
    exit(0)
}

// Проверяем, что запущено с sudo
if getuid() != 0 {
    print("⚠ Предупреждение: Для работы с GPIO требуется запуск с sudo")
}

// Проверяем директорию
let directoryURL = URL(fileURLWithPath: args.directory)
let fm = FileManager.default
let transmitterMode = args.dmaChannel == 0xff ? "CPU" : "DMA \(args.dmaChannel)"

if !fm.fileExists(atPath: directoryURL.path) {
    print("✗ Директория не найдена: \(args.directory)")
    print("  Создайте папку и добавьте туда музыкальные файлы.")
    exit(1)
}

print("""
┌─────────────────────────────────────────┐
│         🏴‍☠️ PIRATE RADIO 🏴‍☠️             │
├─────────────────────────────────────────┤
│  Частота: \(String(format: "%6.1f", args.frequency)) MHz                    │
│  Папка:   \(args.directory.prefix(25).padding(toLength: 25, withPad: " ", startingAt: 0))   │
│  TX:      \(transmitterMode.prefix(25).padding(toLength: 25, withPad: " ", startingAt: 0))   │
│  Режим:   \(args.shuffle ? "Shuffle" : "Sequential")                       │
└─────────────────────────────────────────┘
""")

let station = RadioStation(directory: directoryURL, frequency: args.frequency, dmaChannel: args.dmaChannel)
station.playlist.playbackMode = args.shuffle ? .shuffle : .sequential

let delegate = RadioDelegate()
station.delegate = delegate

// Обработка сигналов для корректного завершения
signal(SIGINT) { _ in
    print("\n⏹ Останавливаем вещание...")
    exit(0)
}

signal(SIGTERM) { _ in
    print("\n⏹ Останавливаем вещание...")
    exit(0)
}

do {
    try station.start()
    print("📡 Вещание начато! Нажмите Ctrl+C для остановки.")
    print("   Команды: n=след. трек, p=пред. трек, s=shuffle, q=выход\n")

    // Читаем команды с клавиатуры
    while station.isBroadcasting {
        if let input = readLine()?.lowercased() {
            switch input {
            case "n":
                station.nextTrack()
            case "p":
                station.previousTrack()
            case "s":
                station.playlist.playbackMode = station.playlist.playbackMode == .shuffle ? .sequential : .shuffle
                print("🔀 Режим: \(station.playlist.playbackMode == .shuffle ? "Shuffle" : "Sequential")")
            case "q":
                station.stop()
            default:
                break
            }
        }
    }
} catch {
    print("✗ Ошибка запуска: \(error.localizedDescription)")
    exit(1)
}
