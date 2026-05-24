#!/usr/bin/env bash
set -Eeuo pipefail

FREQUENCY="100.6"
DURATION_SECONDS="20"
BANDWIDTH="200.0"
INSTALL_DEPS=false
RUN_CPU_FALLBACK=true
GPIO_PIN="4"
POLL_INTERVAL="0.25"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=""
CHILD_PID=""

usage() {
  cat <<'EOF'
Использование:
  sudo ./diagnose-fm-wav.sh [OPTIONS]

Опции:
  --frequency MHz       Частота FM-теста. По умолчанию: 100.6
  --duration SECONDS    Длительность WAV-теста. По умолчанию: 20
  --install-deps        Установить нужные пакеты Debian/Raspberry Pi OS.
  --no-cpu-fallback     Не запускать CPU-режим после ошибки DMA-режима.
  -h, --help            Показать справку.

Что проверяет скрипт:
  1. Генерирует PCM WAV с тоном 1 kHz.
  2. Собирает минимальный C++-тест из Sources/CFMTransmitter.
  3. Запускает прямую передачу WAV через GPIO4 / physical pin 7.
  4. Опрашивает pinctrl/raspi-gpio и сообщает, стал ли GPIO4 функцией GPCLK0.
EOF
}

fail() {
  printf 'ОШИБКА: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Не найдена команда: $1"
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

cleanup() {
  if [[ -n "${CHILD_PID}" ]] && kill -0 "${CHILD_PID}" >/dev/null 2>&1; then
    printf '\nОстанавливаю тестовый процесс передатчика %s\n' "${CHILD_PID}" >&2
    kill "${CHILD_PID}" >/dev/null 2>&1 || true
    wait "${CHILD_PID}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --frequency)
      [[ $# -ge 2 ]] || fail "--frequency требует значение в MHz"
      FREQUENCY="$2"
      shift
      ;;
    --duration)
      [[ $# -ge 2 ]] || fail "--duration требует значение в секундах"
      DURATION_SECONDS="$2"
      shift
      ;;
    --install-deps)
      INSTALL_DEPS=true
      ;;
    --no-cpu-fallback)
      RUN_CPU_FALLBACK=false
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Неизвестная опция: $1"
      ;;
  esac
  shift
done

if [[ "${EUID}" -ne 0 ]]; then
  require_command sudo
  sudo_args=(--frequency "${FREQUENCY}" --duration "${DURATION_SECONDS}")
  [[ "${INSTALL_DEPS}" == true ]] && sudo_args+=(--install-deps)
  [[ "${RUN_CPU_FALLBACK}" == false ]] && sudo_args+=(--no-cpu-fallback)
  exec sudo -E bash "$0" "${sudo_args[@]}"
fi

cd "${SCRIPT_DIR}"

if [[ ! -f "Sources/CFMTransmitter/transmitter.cpp" || ! -f "Sources/CFMTransmitter/wave_reader.cpp" ]]; then
  fail "Запускай скрипт из корня репозитория PirateRadio"
fi

if [[ "${INSTALL_DEPS}" == true ]]; then
  have_command apt-get || fail "apt-get не найден; установи зависимости вручную"
  apt-get update
  apt-get install -y build-essential ffmpeg
fi

require_command g++
require_command ffmpeg
require_command sleep
require_command date

GPIO_GET_COMMAND=()
if have_command pinctrl; then
  GPIO_GET_COMMAND=(pinctrl get)
elif have_command raspi-gpio; then
  GPIO_GET_COMMAND=(raspi-gpio get)
else
  fail "Не найден ни pinctrl, ни raspi-gpio"
fi

if [[ -r /proc/device-tree/model ]]; then
  MODEL="$(tr -d '\0' </proc/device-tree/model)"
else
  MODEL="unknown"
fi

printf 'Плата: %s\n' "${MODEL}"
printf 'Частота: %s MHz\n' "${FREQUENCY}"
printf 'Антенна должна быть подключена к GPIO4, physical pin 7. Physical pin 4 это 5V, не GPIO.\n'

[[ -e /dev/mem ]] || fail "/dev/mem отсутствует"
if [[ ! -e /dev/vcio ]]; then
  printf 'ПРЕДУПРЕЖДЕНИЕ: /dev/vcio отсутствует. DMA-режим может упасть; CPU fallback всё ещё полезен.\n' >&2
fi

WORK_DIR="$(mktemp -d /tmp/pirate-radio-fm-diagnose.XXXXXX)"
CPP_FILE="${WORK_DIR}/fm_wav_test.cpp"
BIN_FILE="${WORK_DIR}/fm_wav_test"
WAV_FILE="${WORK_DIR}/tone1k.wav"

cat >"${CPP_FILE}" <<'CPP'
#include "transmitter.hpp"
#include "wave_reader.hpp"

#include <exception>
#include <iostream>
#include <mutex>
#include <string>

int main(int argc, char **argv) {
    if (argc != 5) {
        std::cerr << "Usage: fm_wav_test <frequency_mhz> <bandwidth_khz> <dma_channel> <wav_path>\n";
        return 2;
    }

    bool enable = true;
    std::mutex mtx;

    try {
        float frequency = std::stof(argv[1]);
        float bandwidth = std::stof(argv[2]);
        unsigned dmaChannel = static_cast<unsigned>(std::stoul(argv[3]));
        std::string wavPath = argv[4];

        std::cout << "Opening WAV: " << wavPath << std::endl;
        WaveReader reader(wavPath, enable, mtx);

        std::cout << "Starting FM transmit at " << frequency
                  << " MHz, bandwidth " << bandwidth
                  << " kHz, dmaChannel " << dmaChannel << std::endl;

        Transmitter transmitter;
        transmitter.Transmit(reader, frequency, bandwidth, dmaChannel, false);

        std::cout << "Transmit finished" << std::endl;
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "ERROR: " << error.what() << std::endl;
        return 1;
    }
}
CPP

printf '\nГенерирую WAV-тон 1 kHz на %s секунд...\n' "${DURATION_SECONDS}"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=1000:sample_rate=22050:duration=${DURATION_SECONDS}" \
  -ar 22050 -ac 1 -acodec pcm_s16le -bitexact \
  "${WAV_FILE}"

printf 'Собираю прямой C++ FM WAV-тест...\n'
g++ -std=c++11 -O3 -Wall \
  -I "${SCRIPT_DIR}/Sources/CFMTransmitter" \
  "${CPP_FILE}" \
  "${SCRIPT_DIR}/Sources/CFMTransmitter/transmitter.cpp" \
  "${SCRIPT_DIR}/Sources/CFMTransmitter/wave_reader.cpp" \
  "${SCRIPT_DIR}/Sources/CFMTransmitter/mailbox.cpp" \
  -pthread -lm \
  -o "${BIN_FILE}"

is_gpclk0() {
  local line="$1"
  [[ "${line}" == *"GPCLK0"* || "${line}" =~ (^|[[:space:]])4:[[:space:]]a0 ]]
}

run_case() {
  local label="$1"
  local dma_channel="$2"
  local log_file="${WORK_DIR}/${label}.log"
  local seen_gpclk0=false
  local status=0
  local gpio_line=""

  printf '\n=== Тест %s: dmaChannel=%s ===\n' "${label}" "${dma_channel}"
  "${BIN_FILE}" "${FREQUENCY}" "${BANDWIDTH}" "${dma_channel}" "${WAV_FILE}" >"${log_file}" 2>&1 &
  CHILD_PID="$!"

  while true; do
    gpio_line="$("${GPIO_GET_COMMAND[@]}" "${GPIO_PIN}" 2>&1 || true)"
    printf '%s %s\n' "$(date '+%H:%M:%S')" "${gpio_line}"

    if is_gpclk0 "${gpio_line}"; then
      seen_gpclk0=true
    fi

    if ! kill -0 "${CHILD_PID}" >/dev/null 2>&1; then
      break
    fi

    sleep "${POLL_INTERVAL}"
  done

  if wait "${CHILD_PID}"; then
    status=0
  else
    status=$?
  fi
  CHILD_PID=""

  printf '\nЛог передатчика %s:\n' "${label}"
  sed -n '1,120p' "${log_file}"

  if [[ "${seen_gpclk0}" == true ]]; then
    printf '\nРЕЗУЛЬТАТ: %s перевёл GPIO4 в GPCLK0. Raspberry Pi действительно выдала FM clock на physical pin 7.\n' "${label}"
    return 0
  fi

  printf '\nРЕЗУЛЬТАТ: %s не перевёл GPIO4 в GPCLK0. Код завершения процесса: %s\n' "${label}" "${status}"
  return 1
}

printf '\nНачальное состояние GPIO4:\n'
"${GPIO_GET_COMMAND[@]}" "${GPIO_PIN}" || true

if run_case "DMA" "0"; then
  printf '\nДИАГНОЗ: прямая WAV-передача работает в DMA-режиме. Если pirate-radio всё ещё показывает GPIO=input, отлаживай Swift/FIFO/ffmpeg-обвязку.\n'
  exit 0
fi

if [[ "${RUN_CPU_FALLBACK}" == true ]]; then
  if run_case "CPU" "255"; then
    printf '\nДИАГНОЗ: CPU-режим работает, DMA-режим нет. Смотри /dev/vcio, mailbox, выделение DMA-памяти или конфликт DMA-канала.\n'
    exit 0
  fi
fi

printf '\nДИАГНОЗ: ни DMA, ни CPU-режим не перевели GPIO4 в GPCLK0. Смотри /dev/mem, mapping peripheral base, совместимость OS/kernel или состояние платы.\n'
exit 1
