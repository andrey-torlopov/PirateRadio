#!/usr/bin/env bash
set -Eeuo pipefail

PRODUCT_NAME="pirate-radio"
INSTALL_PATH="/usr/local/bin/${PRODUCT_NAME}"
RASPBERRY_PI_MODE=false
INSTALL_AFTER_BUILD=false
INSTALL_DEPS=false
RUN_AFTER_INSTALL=false
SKIP_PLATFORM_CHECK=false
MUSIC_DIR="${HOME}/music"
FREQUENCY="100.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/Artifacts"
BUILD_CONFIGURATION="release"
SCRATCH_DIR="${SCRIPT_DIR}/.build/builder"
BUILD_DIR="${SCRATCH_DIR}/${BUILD_CONFIGURATION}"
PRODUCT_PATH="${BUILD_DIR}/${PRODUCT_NAME}"
LOCAL_CACHE_DIR="${SCRIPT_DIR}/.build/local-cache"

timestamp() {
  date -u +"%Y%m%dT%H%M%SZ"
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    require_command sudo
    sudo "$@"
  fi
}

sanitize() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-'
}

usage() {
  cat <<EOF
Usage:
  ./builder.sh [OPTIONS]

Default:
  Build release artifact into Artifacts/.

Raspberry Pi one-command deploy:
  ./builder.sh --raspberry-pi --install-deps

Options:
  --raspberry-pi        Validate Raspberry Pi OS, build artifact, install binary.
  --install            Install built binary to ${INSTALL_PATH}.
  --install-deps       Install apt dependencies: build-essential, git, ffmpeg, curl, ca-certificates.
  --run                Run ${PRODUCT_NAME} after successful install.
  --music-dir PATH     Music directory for final run command. Default: ${MUSIC_DIR}
  --frequency MHz      FM frequency for final run command. Default: ${FREQUENCY}
  --no-platform-check  Skip Raspberry Pi platform checks.
  -h, --help           Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raspberry-pi)
      RASPBERRY_PI_MODE=true
      INSTALL_AFTER_BUILD=true
      ;;
    --install)
      INSTALL_AFTER_BUILD=true
      ;;
    --install-deps)
      INSTALL_DEPS=true
      ;;
    --run)
      RUN_AFTER_INSTALL=true
      INSTALL_AFTER_BUILD=true
      ;;
    --music-dir)
      [[ $# -ge 2 ]] || fail "--music-dir requires a path"
      MUSIC_DIR="$2"
      shift
      ;;
    --frequency)
      [[ $# -ge 2 ]] || fail "--frequency requires MHz value"
      FREQUENCY="$2"
      shift
      ;;
    --no-platform-check)
      SKIP_PLATFORM_CHECK=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
  shift
done

require_command tar
require_command uname

cd "${SCRIPT_DIR}"
mkdir -p "${LOCAL_CACHE_DIR}/clang-module-cache" "${LOCAL_CACHE_DIR}/xdg"

export CLANG_MODULE_CACHE_PATH="${LOCAL_CACHE_DIR}/clang-module-cache"
export XDG_CACHE_HOME="${LOCAL_CACHE_DIR}/xdg"

os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch_name="$(uname -m)"
artifact_stamp="$(timestamp)"

install_apt_dependencies() {
  [[ "${os_name}" == "linux" ]] || fail "--install-deps is only supported on Linux"
  have_command apt-get || fail "apt-get not found; install dependencies manually for this OS"

  printf 'Installing Raspberry Pi build/runtime dependencies with apt...\n'
  run_as_root apt-get update
  run_as_root apt-get install -y build-essential git ffmpeg curl ca-certificates

  if ! have_command swift; then
    if apt-cache show swiftlang >/dev/null 2>&1; then
      run_as_root apt-get install -y swiftlang
    else
      fail "Swift is not installed and apt package swiftlang is unavailable. Install Swift 5.9+ first, then rerun ./builder.sh --raspberry-pi"
    fi
  fi
}

validate_raspberry_pi() {
  "${SKIP_PLATFORM_CHECK}" && return 0

  [[ "${os_name}" == "linux" ]] || fail "--raspberry-pi must be run on Raspberry Pi OS, current OS: ${os_name}"
  [[ "${arch_name}" == "aarch64" || "${arch_name}" == "arm64" ]] || fail "64-bit Raspberry Pi OS is required, current arch: ${arch_name}"

  local model_file="/proc/device-tree/model"
  [[ -r "${model_file}" ]] || fail "Cannot read ${model_file}; this does not look like Raspberry Pi OS"

  local model
  model="$(tr -d '\0' <"${model_file}")"
  [[ "${model}" == *"Raspberry Pi"* || "${model}" == *"Compute Module"* ]] || fail "Unsupported board model: ${model}"

  if [[ "${model}" == *"Raspberry Pi 5"* ]]; then
    fail "Raspberry Pi 5 is not supported by this transmitter code without separate clock/DMA validation"
  fi

  [[ -e /dev/mem ]] || fail "/dev/mem is missing"
  [[ -e /dev/vcio ]] || fail "/dev/vcio is missing; try: sudo modprobe vcio"

  printf 'Raspberry Pi platform: %s\n' "${model}"
}

validate_raspberry_pi_dependencies() {
  "${RASPBERRY_PI_MODE}" || return 0

  have_command ffmpeg || fail "ffmpeg not found. Rerun: ./builder.sh --raspberry-pi --install-deps"
}

verify_dependency_list() {
  local binary_path="$1"
  local output_path="$2"

  if [[ "${os_name}" == "linux" ]]; then
    require_command ldd
    ldd "${binary_path}" >"${output_path}"
    if grep -q 'libbcm_host' "${output_path}"; then
      fail "Binary still depends on libbcm_host.so; inspect ${output_path}"
    fi
  else
    if have_command otool; then
      otool -L "${binary_path}" >"${output_path}"
    else
      printf 'Dependency listing is unavailable on %s\n' "${os_name}" >"${output_path}"
    fi
  fi
}

install_artifact() {
  local binary_path="$1"

  printf 'Installing %s to %s\n' "${binary_path}" "${INSTALL_PATH}"
  run_as_root install -m 0755 "${binary_path}" "${INSTALL_PATH}"

  [[ -x "${INSTALL_PATH}" ]] || fail "Installed binary is not executable: ${INSTALL_PATH}"
  "${INSTALL_PATH}" --version

  if [[ "${os_name}" == "linux" ]]; then
    local installed_deps="${artifact_dir}/installed-dependencies.txt"
    verify_dependency_list "${INSTALL_PATH}" "${installed_deps}"
  fi

  mkdir -p "${MUSIC_DIR}"
}

if "${INSTALL_DEPS}"; then
  install_apt_dependencies
fi

if ! have_command swift; then
  fail "Swift not found. Install Swift 5.9+ or rerun with --install-deps if swiftlang is available for your Raspberry Pi OS"
fi

if "${RASPBERRY_PI_MODE}"; then
  validate_raspberry_pi
  validate_raspberry_pi_dependencies
fi

if have_command sha256sum; then
  checksum_command=(sha256sum)
else
  require_command shasum
  checksum_command=(shasum -a 256)
fi

printf 'Building %s for %s/%s\n' "${PRODUCT_NAME}" "${os_name}" "${arch_name}"

swift build \
  --disable-sandbox \
  --manifest-cache local \
  --cache-path "${LOCAL_CACHE_DIR}/swiftpm-cache" \
  --config-path "${LOCAL_CACHE_DIR}/swiftpm-config" \
  --security-path "${LOCAL_CACHE_DIR}/swiftpm-security" \
  --scratch-path "${SCRATCH_DIR}" \
  -c "${BUILD_CONFIGURATION}" \
  --product "${PRODUCT_NAME}"

[[ -x "${PRODUCT_PATH}" ]] || fail "Build did not produce executable: ${PRODUCT_PATH}"

version_output="$("${PRODUCT_PATH}" --version 2>/dev/null || true)"
if [[ -z "${version_output}" ]]; then
  version_output="${PRODUCT_NAME}-unknown"
fi
version_slug="$(sanitize "${version_output}")"

artifact_name="${PRODUCT_NAME}-${version_slug}-${os_name}-${arch_name}-${artifact_stamp}"
artifact_dir="${ARTIFACTS_DIR}/${artifact_name}"
archive_path="${ARTIFACTS_DIR}/${artifact_name}.tar.gz"

mkdir -p "${artifact_dir}"
cp "${PRODUCT_PATH}" "${artifact_dir}/${PRODUCT_NAME}"
chmod 0755 "${artifact_dir}/${PRODUCT_NAME}"

"${artifact_dir}/${PRODUCT_NAME}" --help >"${artifact_dir}/help.txt"

verify_dependency_list "${artifact_dir}/${PRODUCT_NAME}" "${artifact_dir}/dependencies.txt"

cat >"${artifact_dir}/MANIFEST.txt" <<EOF
product=${PRODUCT_NAME}
version=${version_output}
os=${os_name}
arch=${arch_name}
built_at_utc=${artifact_stamp}
source_dir=${SCRIPT_DIR}
binary=${PRODUCT_NAME}

Run on Raspberry Pi:
  sudo install -m 0755 ${PRODUCT_NAME} /usr/local/bin/${PRODUCT_NAME}
  sudo ${PRODUCT_NAME} -f 100.0 /home/pi/music

Runtime requirements:
  Raspberry Pi OS
  ffmpeg
  /dev/mem
  /dev/vcio
EOF

(
  cd "${artifact_dir}"
  "${checksum_command[@]}" "${PRODUCT_NAME}" MANIFEST.txt help.txt dependencies.txt >SHA256SUMS.txt
)

tar -C "${ARTIFACTS_DIR}" -czf "${archive_path}" "${artifact_name}"
"${checksum_command[@]}" "${archive_path}" >"${archive_path}.sha256"

if "${INSTALL_AFTER_BUILD}"; then
  install_artifact "${artifact_dir}/${PRODUCT_NAME}"
fi

printf '\nArtifact directory:\n  %s\n' "${artifact_dir}"
printf 'Artifact archive:\n  %s\n' "${archive_path}"
printf 'Archive checksum:\n  %s\n' "${archive_path}.sha256"

if "${INSTALL_AFTER_BUILD}"; then
  printf 'Installed binary:\n  %s\n' "${INSTALL_PATH}"
  printf '\nRun command:\n  sudo %s -f %s %s\n' "${INSTALL_PATH}" "${FREQUENCY}" "${MUSIC_DIR}"
fi

if "${RUN_AFTER_INSTALL}"; then
  printf '\nStarting broadcast...\n'
  run_as_root "${INSTALL_PATH}" -f "${FREQUENCY}" "${MUSIC_DIR}"
elif [[ "${os_name}" != "linux" || "${arch_name}" != "aarch64" ]]; then
  printf '\nWARNING: This artifact was built on %s/%s. For Raspberry Pi deployment, run this script on the target Raspberry Pi OS machine.\n' "${os_name}" "${arch_name}" >&2
fi
