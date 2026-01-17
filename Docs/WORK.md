PirateRadio - FM радиостанция на Raspberry Pi

Использование:
  pirate-radio [OPTIONS] [DIRECTORY]

Опции:
  -d, --directory PATH   Папка с музыкой (по умолчанию: ./music)
  -f, --frequency MHz    Частота вещания (по умолчанию: 100.0)
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

---
SPM-пакет готов. Вот структура проекта:

```
PirateRadio/
├── Package.swift
├── Sources/
│   ├── CFMTransmitter/          # C++ библиотека fm_transmitter
│   │   ├── include/
│   │   │   ├── CFMTransmitter.h # C API для Swift
│   │   │   └── module.modulemap
│   │   ├── shim.cpp             # C обёртка над C++ кодом
│   │   ├── transmitter.cpp/hpp  # FM передатчик (Raspberry Pi)
│   │   ├── wave_reader.cpp/hpp  # Чтение WAV файлов
│   │   └── mailbox.cpp/hpp      # Broadcom mailbox API
│   ├── FMTransmitter/           # Swift библиотека
│   │   ├── FMTransmitter.swift  # Swift API для передатчика
│   │   ├── Playlist.swift       # Менеджер плейлиста
│   │   ├── AudioConverter.swift # Конвертация через ffmpeg
│   │   └── RadioStation.swift   # Главный класс радиостанции
│   └── PirateRadio/             # CLI приложение
│       └── main.swift
```

---

Для запуска на Raspberry Pi:**

1. Установите зависимости:
```bash
sudo apt-get install -y build-essential libraspberrypi-dev ffmpeg
```

2. Установите Swift 5.9 (если ещё нет)

3. Соберите проект:
```bash
swift build -c release
```

4. Запустите:
```bash
sudo .build/release/pirate-radio -f 100.0 ~/music
```

**Как это работает:**
- Приложение сканирует указанную папку на mp3/wav/flac файлы
- Через ffmpeg конвертирует их в WAV PCM поток
- Передаёт поток в fm_transmitter, который модулирует GPIO для FM вещания
- Поддерживает shuffle, управление с клавиатуры (n/p/s/q)
- Мониторит папку на изменения

**Примечание:** На macOS собирается со stub-реализацией (для разработки), реальная FM-передача работает только на Raspberry Pi с Linux.
