#!/usr/bin/env bash
set -Eeuo pipefail

PRODUCT_NAME="pirate-radio"

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

sanitize() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-'
}

require_command swift
require_command tar
require_command uname

cd "${SCRIPT_DIR}"
mkdir -p "${LOCAL_CACHE_DIR}/clang-module-cache" "${LOCAL_CACHE_DIR}/xdg"

export CLANG_MODULE_CACHE_PATH="${LOCAL_CACHE_DIR}/clang-module-cache"
export XDG_CACHE_HOME="${LOCAL_CACHE_DIR}/xdg"

os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch_name="$(uname -m)"
artifact_stamp="$(timestamp)"

if command -v sha256sum >/dev/null 2>&1; then
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

if [[ "${os_name}" == "linux" ]]; then
  require_command ldd
  ldd "${artifact_dir}/${PRODUCT_NAME}" >"${artifact_dir}/dependencies.txt"
  if grep -q 'libbcm_host' "${artifact_dir}/dependencies.txt"; then
    fail "Artifact still depends on libbcm_host.so; inspect ${artifact_dir}/dependencies.txt"
  fi
else
  if command -v otool >/dev/null 2>&1; then
    otool -L "${artifact_dir}/${PRODUCT_NAME}" >"${artifact_dir}/dependencies.txt"
  else
    printf 'Dependency listing is unavailable on %s\n' "${os_name}" >"${artifact_dir}/dependencies.txt"
  fi
fi

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

printf '\nArtifact directory:\n  %s\n' "${artifact_dir}"
printf 'Artifact archive:\n  %s\n' "${archive_path}"
printf 'Archive checksum:\n  %s\n' "${archive_path}.sha256"

if [[ "${os_name}" != "linux" || "${arch_name}" != "aarch64" ]]; then
  printf '\nWARNING: This artifact was built on %s/%s. For Raspberry Pi deployment, run this script on the target Raspberry Pi OS machine.\n' "${os_name}" "${arch_name}" >&2
fi
