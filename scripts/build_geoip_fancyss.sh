#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
SRC_DIR="${REPO_ROOT}/rules_ng2/ip"
OUT_DIR="${REPO_ROOT}/rules_ng2/dat"
PKG_DIR="${REPO_ROOT}/fancyss/ss/rules_ng2/dat"
OUT_FILE="${OUT_DIR}/geoip.dat"
BASE_DIR="${REPO_ROOT}/.build_geodata"
WORK_DIR="${BASE_DIR}/geoip"
GEOIP_REPO="https://github.com/v2fly/geoip.git"
GO_BIN="$("${SCRIPT_DIR}/ensure_local_go.sh")"

command -v git >/dev/null 2>&1 || { echo "missing dependency: git" >&2; exit 1; }
[ -d "${SRC_DIR}" ] || { echo "missing source dir: ${SRC_DIR}" >&2; exit 1; }
[ -x "${GO_BIN}" ] || { echo "missing go toolchain: ${GO_BIN}" >&2; exit 1; }

mkdir -p "${OUT_DIR}" "${PKG_DIR}" "${BASE_DIR}"

REVISION="$(jq -er '.rule_compilers["geoip"]' "$REPO_ROOT/build-inputs.lock.json")"
if [ ! -d "${WORK_DIR}/.git" ]; then
    [ "${FSS_OFFLINE:-0}" != 1 ] || { echo "Missing cached rule compiler" >&2; exit 1; }
    git init "${WORK_DIR}" >/dev/null 2>&1
    git -C "${WORK_DIR}" remote add origin "${GEOIP_REPO}"
fi
cd "${WORK_DIR}"
if ! git cat-file -e "$REVISION^{commit}" 2>/dev/null; then
    [ "${FSS_OFFLINE:-0}" != 1 ] || { echo "Missing locked rule compiler commit" >&2; exit 1; }
    git fetch --depth=1 origin "$REVISION" >/dev/null 2>&1
fi
git checkout -f --detach "$REVISION" >/dev/null 2>&1
git clean -fdqx >/dev/null 2>&1
mkdir -p "${WORK_DIR}/data"
rm -f "${WORK_DIR}/data/"*.txt
for src in "${SRC_DIR}"/*.txt
do
	[ -f "${src}" ] || continue
	cp -f "${src}" "${WORK_DIR}/data/$(basename "${src}" .txt).txt"
done
cat > "${WORK_DIR}/config.fancyss.json" <<-EOF
{
  "input": [
    {
      "type": "text",
      "action": "add",
      "args": {
        "inputDir": "./data"
      }
    }
  ],
  "output": [
    {
      "type": "v2rayGeoIPDat",
      "action": "output",
      "args": {
        "outputDir": "${OUT_DIR}",
        "outputName": "geoip.dat"
      }
    }
  ]
}
EOF
(
	cd "${WORK_DIR}"
	PATH="$(dirname "${GO_BIN}"):${PATH}" "${GO_BIN}" run ./ -c ./config.fancyss.json >/dev/null
)
cp -f "${OUT_FILE}" "${PKG_DIR}/geoip.dat"

echo "built ${OUT_FILE}"
