# PirateRadio

FM-радиостанция на Raspberry Pi. Транслирует музыку из папки на выбранной FM-частоте.

## Требования

### Hardware
- Raspberry Pi (любая модель с GPIO)
- Провод 20-40 см к GPIO 4 (pin 7) в качестве антенны

### Software
- Swift 5.9+
- ffmpeg
- Raspberry Pi OS (или другой Linux с доступом к `/dev/mem`)

## Установка

### 1. Установка зависимостей

```bash
# ffmpeg для конвертации аудио
sudo apt update
sudo apt install ffmpeg

# Swift (если не установлен)
curl -s https://archive.swiftlang.xyz/install.sh | sudo bash
sudo apt install swiftlang
```

### 2. Сборка проекта

```bash
git clone https://github.com/yourname/PirateRadio.git
cd PirateRadio
swift build -c release
```

Исполняемый файл будет в `.build/release/pirate-radio`.

### 3. Установка (опционально)

```bash
sudo cp .build/release/pirate-radio /usr/local/bin/
```

## Использование

### Быстрый старт

```bash
# Создайте папку с музыкой
mkdir ~/music
cp /path/to/your/*.mp3 ~/music/

# Запустите вещание на 100.0 MHz
sudo pirate-radio ~/music
```

### Опции командной строки

```
pirate-radio [OPTIONS] [DIRECTORY]

Опции:
  -d, --directory PATH   Папка с музыкой (по умолчанию: ./music)
  -f, --frequency MHz    Частота вещания (по умолчанию: 100.0)
  -s, --shuffle          Случайный порядок треков
  -h, --help             Показать справку
  -v, --version          Показать версию
```

### Примеры

```bash
# Вещание на 88.5 MHz
sudo pirate-radio -f 88.5 ~/music

# Shuffle-режим
sudo pirate-radio --shuffle -f 100.0 ~/music

# Указание папки через флаг
sudo pirate-radio -d /home/pi/radio -f 99.5
```

### Управление во время работы

| Клавиша | Действие |
|---------|----------|
| `n` | Следующий трек |
| `p` | Предыдущий трек |
| `s` | Вкл/выкл shuffle |
| `q` | Выход |
| `Ctrl+C` | Выход |

## Поддерживаемые форматы

- MP3
- WAV
- FLAC
- OGG
- M4A
- AAC
- WMA

Файлы автоматически конвертируются в нужный формат через ffmpeg.

## Архитектура

```
┌─────────────┐    ┌─────────┐    ┌───────────────┐    ┌─────────┐
│ Audio Files │───▶│ ffmpeg  │───▶│ fm_transmitter│───▶│ GPIO 4  │~~~▶ FM
└─────────────┘    └─────────┘    └───────────────┘    └─────────┘
                   PCM stream         RF signal         Antenna
```

Файлы стримятся по одному, не загружаются в память целиком. Безопасно для папок любого размера.

## Запуск как сервис (systemd)

Создайте файл `/etc/systemd/system/pirate-radio.service`:

```ini
[Unit]
Description=PirateRadio FM Transmitter
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pirate-radio -f 100.0 -s /home/pi/music
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Активация:

```bash
sudo systemctl daemon-reload
sudo systemctl enable pirate-radio
sudo systemctl start pirate-radio
```

Просмотр логов:

```bash
journalctl -u pirate-radio -f
```

## Troubleshooting

### "Требуется запуск с sudo"

Доступ к GPIO требует root-прав:

```bash
sudo pirate-radio ~/music
```

### "fm_transmitter не найден"

Убедитесь, что проект собран и бинарник доступен.

### Нет звука на приёмнике

1. Проверьте, что антенна подключена к GPIO 4 (pin 7)
2. Попробуйте другую частоту (100.0, 88.5, 107.0)
3. Поднесите приёмник ближе к Raspberry Pi

### ffmpeg не найден

```bash
sudo apt install ffmpeg
```

## Легальность

Передача FM-сигнала может быть незаконной в вашей стране без лицензии. Используйте на свой риск и только в образовательных целях с минимальной мощностью сигнала.

## Лицензия

MIT
