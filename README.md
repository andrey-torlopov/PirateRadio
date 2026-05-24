# PirateRadio

FM-радиостанция на Raspberry Pi. Транслирует музыку из папки на выбранной FM-частоте.

> Важно: проект работает с низкоуровневыми регистрами Raspberry Pi через `/dev/mem` и `/dev/vcio`.
> Запускайте только на своём оборудовании, на минимальной мощности и с учётом местного законодательства.

## Требования

### Hardware
- Raspberry Pi с GPIO и Raspberry Pi OS 64-bit.
- Целевые модели: Raspberry Pi Zero 2 W, 3, 4, 400, Compute Module 3/4.
- Raspberry Pi 5 пока не считается поддержанной платформой: у неё другая SoC-платформа, работу FM-части нужно отдельно проверять.
- Провод 20-40 см к GPIO 4 (pin 7) в качестве антенны

### Software
- Swift 5.9+
- ffmpeg
- Raspberry Pi OS с доступом к `/dev/mem` и `/dev/vcio`

## Установка

### 1. Установка зависимостей

```bash
sudo apt update
sudo apt install -y build-essential git ffmpeg

# Swift (если не установлен)
curl -s https://archive.swiftlang.xyz/install.sh | sudo bash
sudo apt install swiftlang
```

Проверьте, что Swift доступен:

```bash
swift --version
```

### 2. Полная сборка и установка на Raspberry Pi

На Raspberry Pi OS из корня проекта запустите одну команду:

```bash
./builder.sh --raspberry-pi --install-deps --music-dir ~/music --frequency 100.0
```

Что сделает скрипт:

- проверит, что запуск идёт на Raspberry Pi OS 64-bit;
- установит apt-зависимости `build-essential`, `git`, `ffmpeg`, `curl`, `ca-certificates`;
- проверит наличие Swift;
- соберёт release-бинарь;
- сохранит артефакт в `Artifacts`;
- проверит, что бинарь не зависит от `libbcm_host.so`;
- установит `pirate-radio` в `/usr/local/bin/pirate-radio`;
- напечатает готовую команду запуска.

Если Swift ещё не установлен и пакет `swiftlang` недоступен в apt, сначала установите Swift 5.9+, затем повторите команду выше.

Чтобы после сборки и установки сразу запустить вещание:

```bash
./builder.sh --raspberry-pi --install-deps --run --music-dir ~/music --frequency 100.0
```

Перед `--run` положите музыку в указанную папку:

```bash
mkdir -p ~/music
cp /path/to/your/*.mp3 ~/music/
```

### 3. Только сборка артефакта

```bash
git clone https://github.com/yourname/PirateRadio.git
cd PirateRadio
./builder.sh
```

Скрипт соберёт release-бинарь и сохранит результат в `Artifacts`:

```text
Artifacts/
├── pirate-radio-.../
│   ├── pirate-radio
│   ├── MANIFEST.txt
│   ├── dependencies.txt
│   ├── help.txt
│   └── SHA256SUMS.txt
├── pirate-radio-....tar.gz
└── pirate-radio-....tar.gz.sha256
```

Для Raspberry Pi запускайте `builder.sh` именно на Raspberry Pi OS. SwiftPM не делает универсальный бинарь: артефакт, собранный на macOS, не запустится на Raspberry Pi.

Проверьте, что бинарь больше не зависит от `libbcm_host.so`:

```bash
ldd Artifacts/pirate-radio-*/pirate-radio | grep bcm_host || echo "OK: libbcm_host не требуется"
```

### 4. Ручная установка артефакта

Если артефакт уже лежит на Raspberry Pi после `./builder.sh`, установите бинарь из последней директории:

```bash
artifact_dir="$(ls -dt Artifacts/pirate-radio-*/ | head -n 1)"
sudo install -m 0755 "${artifact_dir}/pirate-radio" /usr/local/bin/pirate-radio
```

Если вы переносите `.tar.gz` на другую Raspberry Pi с такой же архитектурой и ОС:

```bash
mkdir -p ~/pirate-radio-artifact
tar -xzf pirate-radio-*.tar.gz -C ~/pirate-radio-artifact
cd ~/pirate-radio-artifact/pirate-radio-*
sha256sum -c SHA256SUMS.txt
sudo install -m 0755 pirate-radio /usr/local/bin/pirate-radio
```

Проверьте установленный бинарь:

```bash
which pirate-radio
pirate-radio --version
ldd "$(which pirate-radio)" | grep bcm_host || echo "OK: установленный бинарь не требует libbcm_host"
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
┌─────────────┐    ┌─────────┐    ┌────────────┐    ┌────────────────┐    ┌─────────┐
│ Audio Files │───▶│ ffmpeg  │───▶│ WAV FIFO   │───▶│ CFMTransmitter │───▶│ GPIO 4  │~~~▶ FM
└─────────────┘    └─────────┘    └────────────┘    └────────────────┘    └─────────┘
                   PCM stream      named pipe       DMA/clock control     Antenna
```

Файлы стримятся по одному через `ffmpeg` и временный FIFO. Внешний бинарь `fm_transmitter` не нужен: C++-часть встроена в `pirate-radio`.

Проект не линкуется с `libbcm_host.so`. Базовый адрес и размер периферии Raspberry Pi определяются из Linux device tree (`/proc/device-tree/soc/ranges`). Это убирает зависимость от legacy-пути `/opt/vc/lib`.

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

### `pirate-radio: error while loading shared libraries: libbcm_host.so`

Причина: вы запускаете старый бинарь, собранный с зависимостью от Broadcom userland library `libbcm_host.so`, либо в системе нет пакета с этой библиотекой.

Правильное исправление для текущей версии проекта — пересобрать и переустановить `pirate-radio`:

```bash
cd PirateRadio
./builder.sh
artifact_dir="$(ls -dt Artifacts/pirate-radio-*/ | head -n 1)"
ldd "${artifact_dir}/pirate-radio" | grep bcm_host || echo "OK: libbcm_host не требуется"
sudo install -m 0755 "${artifact_dir}/pirate-radio" /usr/local/bin/pirate-radio
```

Проверьте, какой бинарь реально запускается:

```bash
which pirate-radio
ldd "$(which pirate-radio)" | grep bcm_host || echo "OK: установленный бинарь не требует libbcm_host"
```

Если вы сознательно запускаете старую версию проекта, временный обходной путь:

```bash
sudo apt install -y libraspberrypi0 libraspberrypi-dev
sudo ldconfig
```

Но это именно обходной путь для старого бинаря, а не требование текущей версии.

### "Требуется запуск с sudo"

Доступ к GPIO требует root-прав:

```bash
sudo pirate-radio ~/music
```

### "Can't open device file: /dev/vcio"

Проверьте, что вы запускаете проект на Raspberry Pi OS, а не на обычном Linux. Затем проверьте устройство:

```bash
ls -l /dev/vcio
```

Если файла нет, попробуйте загрузить модуль:

```bash
sudo modprobe vcio
ls -l /dev/vcio
```

Если `/dev/vcio` всё ещё отсутствует, текущая ОС/ядро не предоставляет нужный mailbox-интерфейс.

### Нет звука на приёмнике

1. Проверьте, что антенна подключена к GPIO 4 (pin 7)
2. Попробуйте другую частоту (100.0, 88.5, 107.0)
3. Поднесите приёмник ближе к Raspberry Pi
4. Убедитесь, что запущен именно новый бинарь: `which pirate-radio`

### ffmpeg не найден

```bash
sudo apt install -y ffmpeg
```

## Легальность

Передача FM-сигнала может быть незаконной в вашей стране без лицензии. Используйте на свой риск и только в образовательных целях с минимальной мощностью сигнала.

## Лицензия

MIT
