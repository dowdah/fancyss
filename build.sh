#!/usr/bin/env bash
set -euo pipefail

MODULE=shadowsocks
SOURCE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
VERSION=$(sed -n 1p "$SOURCE_DIR/fancyss/ss/version")
TITLE="科学上网"
DESCRIPTION="科学上网"
HOME_URL=Module_shadowsocks.asp
CURR_PATH="$( cd "$( dirname "$BASH_SOURCE[0]" )" && pwd )"

PACKAGES_DIR="${CURR_PATH}/packages"

cp_rules(){
	local target=${CURR_PATH}/fancyss/ss/rules/
	cp -rf ${CURR_PATH}/rules_ng/gfwlist.gz ${target}
	cp -rf ${CURR_PATH}/rules_ng/chnlist.gz ${target}
	cp -rf ${CURR_PATH}/rules_ng/adslist.gz ${target}
	cp -rf ${CURR_PATH}/rules_ng/udplist.txt ${target}
	cp -rf ${CURR_PATH}/rules_ng/rotlist.txt ${target}
	cp -rf ${CURR_PATH}/rules_ng/white_list.txt ${target}
	cp -rf ${CURR_PATH}/rules_ng/black_list.txt ${target}
	cp -rf ${CURR_PATH}/rules_ng/block_list.txt ${target}
	cp -rf ${CURR_PATH}/rules_ng/apple_china.txt ${target}
	cp -rf ${CURR_PATH}/rules_ng/google_china.txt ${target}
	cp -rf ${CURR_PATH}/rules_ng/cdn_test.txt ${target}
	cp -rf ${CURR_PATH}/rules_ng/chnroute.txt ${target}
	cp -rf ${CURR_PATH}/rules_ng/chnroute6.txt ${target}
	cp -rf ${CURR_PATH}/rules_ng/rules.json.js ${target}
}

cp_rules_ng2(){
	local src=${CURR_PATH}/rules_ng2
	local target=${CURR_PATH}/fancyss/ss/rules_ng2
	rm -rf ${target}
	if [ -d "${src}" ];then
		mkdir -p ${CURR_PATH}/fancyss/ss
		cp -rf ${src} ${target}
	fi
}

prepare_geodata_assets(){
	echo ">>> refresh rules_ng2 manifest and package mirror"
	${CURR_PATH}/scripts/update_geodata_assets.sh --no-fetch
	echo ">>> build geosite/geoip dat assets"
	${CURR_PATH}/scripts/build_geodata_fancyss.sh
}

zig_tool_version(){
	local tool_dir="$1"
	tr -d '\r\n' < "${CURR_PATH}/tool/${tool_dir}/VERSION"
}

set_pkg_web_meta(){
	local file_path="$1"
	local pkg_name="$2"
	local pkg_arch="$3"
	local pkg_type="$4"
	local pkg_exta="$5"
	sed -i "s/^var PKG_NAME=.*/var PKG_NAME=\"${pkg_name}\"/" "${file_path}"
	sed -i "s/^var PKG_ARCH=.*/var PKG_ARCH=\"${pkg_arch}\"/" "${file_path}"
	sed -i "s/^var PKG_TYPE=.*/var PKG_TYPE=\"${pkg_type}\"/" "${file_path}"
	sed -i "s/^var PKG_EXTA=.*/var PKG_EXTA=\"${pkg_exta}\"/" "${file_path}"
}

sync_binary(){
	# BINS_REMOVE="naive"
	# for BIN_REMOVE in $BINS_REMOVE;
	# do
	# 	echo ">>> remove old bin $BIN_REMOVE"
	# 	rm -rf ${CURR_PATH}/fancyss/bin-mtk/${BIN_REMOVE}
	# 	rm -rf ${CURR_PATH}/fancyss/bin-hnd_v8/${BIN_REMOVE}
	# 	rm -rf ${CURR_PATH}/fancyss/bin-hnd/${BIN_REMOVE}
	# 	rm -rf ${CURR_PATH}/fancyss/bin-qca/${BIN_REMOVE}
	# 	rm -rf ${CURR_PATH}/fancyss/bin-arm/${BIN_REMOVE}
	# 	rm -rf ${CURR_PATH}/fancyss/bin-ipq32/${BIN_REMOVE}
	# 	rm -rf ${CURR_PATH}/fancyss/bin-ipq64/${BIN_REMOVE}
	# done

	# update to latest binary
	BINS_COPY="xray naive ipt2socks"
	for BIN in $BINS_COPY;
	do
		local VERSION_FLAG="latest.txt"

		if [ "${BIN}" == "xray" ];then
			local VERSION_FLAG="latest_2.txt"
		fi

		local version=$(cat ${CURR_PATH}/binaries/${BIN}/${VERSION_FLAG})
		echo ">>> start to copy latest ${BIN}, version: ${version}"
		cp -rf ${CURR_PATH}/binaries/${BIN}/${version}/${BIN}_arm64 ${CURR_PATH}/fancyss/bin-mtk/${BIN}
		cp -rf ${CURR_PATH}/binaries/${BIN}/${version}/${BIN}_arm64 ${CURR_PATH}/fancyss/bin-hnd_v8/${BIN}
		cp -rf ${CURR_PATH}/binaries/${BIN}/${version}/${BIN}_armv7 ${CURR_PATH}/fancyss/bin-ipq32/${BIN}
		cp -rf ${CURR_PATH}/binaries/${BIN}/${version}/${BIN}_armv7 ${CURR_PATH}/fancyss/bin-hnd/${BIN}
		cp -rf ${CURR_PATH}/binaries/${BIN}/${version}/${BIN}_armv7 ${CURR_PATH}/fancyss/bin-qca/${BIN}
		cp -rf ${CURR_PATH}/binaries/${BIN}/${version}/${BIN}_armv5 ${CURR_PATH}/fancyss/bin-arm/${BIN}
	done

	local TUIC_VERSION=$(cat ${CURR_PATH}/binaries/tuic-client/latest.txt)
	echo ">>> start to copy latest tuic-client, version: ${TUIC_VERSION}"
	cp -rf ${CURR_PATH}/binaries/tuic-client/${TUIC_VERSION}/tuic-client_arm64 ${CURR_PATH}/fancyss/bin-mtk/tuic-client
	cp -rf ${CURR_PATH}/binaries/tuic-client/${TUIC_VERSION}/tuic-client_arm64 ${CURR_PATH}/fancyss/bin-hnd_v8/tuic-client
	cp -rf ${CURR_PATH}/binaries/tuic-client/${TUIC_VERSION}/tuic-client_armv7 ${CURR_PATH}/fancyss/bin-ipq32/tuic-client
	cp -rf ${CURR_PATH}/binaries/tuic-client/${TUIC_VERSION}/tuic-client_armv7 ${CURR_PATH}/fancyss/bin-hnd/tuic-client
	cp -rf ${CURR_PATH}/binaries/tuic-client/${TUIC_VERSION}/tuic-client_armv7 ${CURR_PATH}/fancyss/bin-qca/tuic-client
	cp -rf ${CURR_PATH}/binaries/tuic-client/${TUIC_VERSION}/tuic-client_armv7 ${CURR_PATH}/fancyss/bin-arm/tuic-client

	local upx=".upx"
	
	cp -rf ${CURR_PATH}/binaries/chinadns-ng/chinadns-ng+wolfssl@aarch64-linux-musl@generic+v8a@fast+lto$upx ${CURR_PATH}/fancyss/bin-mtk/chinadns-ng
	cp -rf ${CURR_PATH}/binaries/chinadns-ng/chinadns-ng+wolfssl@aarch64-linux-musl@generic+v8a@fast+lto$upx ${CURR_PATH}/fancyss/bin-hnd_v8/chinadns-ng
	cp -rf ${CURR_PATH}/binaries/chinadns-ng/chinadns-ng+wolfssl@arm-linux-musleabi@generic+v7a@fast+lto$upx ${CURR_PATH}/fancyss/bin-ipq32/chinadns-ng
	cp -rf ${CURR_PATH}/binaries/chinadns-ng/chinadns-ng+wolfssl@arm-linux-musleabi@generic+v7a@fast+lto$upx ${CURR_PATH}/fancyss/bin-hnd/chinadns-ng
	cp -rf ${CURR_PATH}/binaries/chinadns-ng/chinadns-ng+wolfssl@arm-linux-musleabi@generic+v7a@fast+lto$upx ${CURR_PATH}/fancyss/bin-qca/chinadns-ng
	cp -rf ${CURR_PATH}/binaries/chinadns-ng/chinadns-ng+wolfssl@arm-linux-musleabi@generic+v5te+soft_float@fast+lto$upx ${CURR_PATH}/fancyss/bin-arm/chinadns-ng

	local GEOTOOL_VER="v$(zig_tool_version geotool)"
	cp -rf ${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-mtk/geotool
	cp -rf ${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-hnd_v8/geotool
	cp -rf ${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-ipq64/geotool
	cp -rf ${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-ipq32/geotool
	cp -rf ${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-armv7hf ${CURR_PATH}/fancyss/bin-hnd/geotool
	cp -rf ${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-qca/geotool
	cp -rf ${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-armv5te ${CURR_PATH}/fancyss/bin-arm/geotool

	local XAPITOOL_VER="v$(zig_tool_version xapi-tool)"
	cp -rf ${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-mtk/xapi-tool
	cp -rf ${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-hnd_v8/xapi-tool
	cp -rf ${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-ipq64/xapi-tool
	cp -rf ${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-ipq32/xapi-tool
	cp -rf ${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-armv7hf ${CURR_PATH}/fancyss/bin-hnd/xapi-tool
	cp -rf ${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-qca/xapi-tool

	local SUBTOOL_VER="v$(zig_tool_version sub-tool)"
	cp -rf ${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-mtk/sub-tool
	cp -rf ${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-hnd_v8/sub-tool
	cp -rf ${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-ipq64/sub-tool
	cp -rf ${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-ipq32/sub-tool
	cp -rf ${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-armv7hf ${CURR_PATH}/fancyss/bin-hnd/sub-tool
	cp -rf ${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-qca/sub-tool
	cp -rf ${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-armv5te ${CURR_PATH}/fancyss/bin-arm/sub-tool

	local NODETOOL_VER="v$(zig_tool_version node-tool)"
	cp -rf ${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-mtk/node-tool
	cp -rf ${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-hnd_v8/node-tool
	cp -rf ${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-ipq64/node-tool
	cp -rf ${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-ipq32/node-tool
	cp -rf ${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-armv7hf ${CURR_PATH}/fancyss/bin-hnd/node-tool
	cp -rf ${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-qca/node-tool
	cp -rf ${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-armv5te ${CURR_PATH}/fancyss/bin-arm/node-tool

	local WEBSOCKETD_VER="v$(zig_tool_version ws-tool)"
	cp -rf ${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-mtk/websocketd
	cp -rf ${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-hnd_v8/websocketd
	cp -rf ${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-ipq64/websocketd
	cp -rf ${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-ipq32/websocketd
	cp -rf ${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-armv7hf ${CURR_PATH}/fancyss/bin-hnd/websocketd
	cp -rf ${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-qca/websocketd
	cp -rf ${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-armv5te ${CURR_PATH}/fancyss/bin-arm/websocketd

	local STATUSTOOL_VER="v$(zig_tool_version status-tool)"
	cp -rf ${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-mtk/status-tool
	cp -rf ${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-hnd_v8/status-tool
	cp -rf ${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-ipq64/status-tool
	cp -rf ${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-ipq32/status-tool
	cp -rf ${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-armv7hf ${CURR_PATH}/fancyss/bin-hnd/status-tool
	cp -rf ${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-qca/status-tool
	cp -rf ${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-armv5te ${CURR_PATH}/fancyss/bin-arm/status-tool
	cp -rf ${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-mtk/statusctl
	cp -rf ${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-hnd_v8/statusctl
	cp -rf ${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-ipq64/statusctl
	cp -rf ${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-ipq32/statusctl
	cp -rf ${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-armv7hf ${CURR_PATH}/fancyss/bin-hnd/statusctl
	cp -rf ${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-qca/statusctl
	cp -rf ${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-armv5te ${CURR_PATH}/fancyss/bin-arm/statusctl

	local WEBTESTTOOL_VER="v$(zig_tool_version webtest-tool)"
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-mtk/webtest-tool
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-hnd_v8/webtest-tool
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-ipq64/webtest-tool
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-ipq32/webtest-tool
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-armv7hf ${CURR_PATH}/fancyss/bin-hnd/webtest-tool
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-qca/webtest-tool
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-armv5te ${CURR_PATH}/fancyss/bin-arm/webtest-tool
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-mtk/webtestctl
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-hnd_v8/webtestctl
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-aarch64 ${CURR_PATH}/fancyss/bin-ipq64/webtestctl
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-ipq32/webtestctl
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-armv7hf ${CURR_PATH}/fancyss/bin-hnd/webtestctl
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-armv7a ${CURR_PATH}/fancyss/bin-qca/webtestctl
	cp -rf ${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-armv5te ${CURR_PATH}/fancyss/bin-arm/webtestctl
}

verify_zig_tool_binaries(){
	local bin_platform=""
	local source_file=""
	local target_file=""
	local missing=0

	verify_zig_copy(){
		source_file="$1"
		bin_platform="$2"
		target_file="$3"
		target_file="${CURR_PATH}/fancyss/bin-${bin_platform}/${target_file}"

		if [ ! -x "${target_file}" ]; then
			echo "!!! missing Zig tool binary: ${target_file#${CURR_PATH}/}" >&2
			missing=1
			return
		fi
		if ! cmp -s "${source_file}" "${target_file}"; then
			echo "!!! stale Zig tool binary: ${target_file#${CURR_PATH}/} != ${source_file#${CURR_PATH}/}" >&2
			missing=1
		fi
	}

	local GEOTOOL_VER="v$(zig_tool_version geotool)"
	verify_zig_copy "${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-aarch64" mtk geotool
	verify_zig_copy "${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-aarch64" hnd_v8 geotool
	verify_zig_copy "${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-aarch64" ipq64 geotool
	verify_zig_copy "${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-armv7a" ipq32 geotool
	verify_zig_copy "${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-armv7hf" hnd geotool
	verify_zig_copy "${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-armv7a" qca geotool
	verify_zig_copy "${CURR_PATH}/binaries/geotool/geotool-${GEOTOOL_VER}-linux-armv5te" arm geotool

	local XAPITOOL_VER="v$(zig_tool_version xapi-tool)"
	verify_zig_copy "${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-aarch64" mtk xapi-tool
	verify_zig_copy "${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-aarch64" hnd_v8 xapi-tool
	verify_zig_copy "${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-aarch64" ipq64 xapi-tool
	verify_zig_copy "${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-armv7a" ipq32 xapi-tool
	verify_zig_copy "${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-armv7hf" hnd xapi-tool
	verify_zig_copy "${CURR_PATH}/binaries/xapi-tool/xapi-tool-${XAPITOOL_VER}-linux-armv7a" qca xapi-tool

	local SUBTOOL_VER="v$(zig_tool_version sub-tool)"
	verify_zig_copy "${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-aarch64" mtk sub-tool
	verify_zig_copy "${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-aarch64" hnd_v8 sub-tool
	verify_zig_copy "${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-aarch64" ipq64 sub-tool
	verify_zig_copy "${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-armv7a" ipq32 sub-tool
	verify_zig_copy "${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-armv7hf" hnd sub-tool
	verify_zig_copy "${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-armv7a" qca sub-tool
	verify_zig_copy "${CURR_PATH}/binaries/sub-tool/sub-tool-${SUBTOOL_VER}-linux-armv5te" arm sub-tool

	local NODETOOL_VER="v$(zig_tool_version node-tool)"
	verify_zig_copy "${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-aarch64" mtk node-tool
	verify_zig_copy "${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-aarch64" hnd_v8 node-tool
	verify_zig_copy "${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-aarch64" ipq64 node-tool
	verify_zig_copy "${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-armv7a" ipq32 node-tool
	verify_zig_copy "${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-armv7hf" hnd node-tool
	verify_zig_copy "${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-armv7a" qca node-tool
	verify_zig_copy "${CURR_PATH}/binaries/node-tool/node-tool-${NODETOOL_VER}-linux-armv5te" arm node-tool

	local WEBSOCKETD_VER="v$(zig_tool_version ws-tool)"
	verify_zig_copy "${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-aarch64" mtk websocketd
	verify_zig_copy "${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-aarch64" hnd_v8 websocketd
	verify_zig_copy "${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-aarch64" ipq64 websocketd
	verify_zig_copy "${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-armv7a" ipq32 websocketd
	verify_zig_copy "${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-armv7hf" hnd websocketd
	verify_zig_copy "${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-armv7a" qca websocketd
	verify_zig_copy "${CURR_PATH}/binaries/websocketd/websocketd-${WEBSOCKETD_VER}-linux-armv5te" arm websocketd

	local STATUSTOOL_VER="v$(zig_tool_version status-tool)"
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-aarch64" mtk status-tool
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-aarch64" hnd_v8 status-tool
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-aarch64" ipq64 status-tool
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-armv7a" ipq32 status-tool
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-armv7hf" hnd status-tool
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-armv7a" qca status-tool
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/status-tool-${STATUSTOOL_VER}-linux-armv5te" arm status-tool
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-aarch64" mtk statusctl
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-aarch64" hnd_v8 statusctl
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-aarch64" ipq64 statusctl
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-armv7a" ipq32 statusctl
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-armv7hf" hnd statusctl
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-armv7a" qca statusctl
	verify_zig_copy "${CURR_PATH}/binaries/status-tool/statusctl-${STATUSTOOL_VER}-linux-armv5te" arm statusctl

	local WEBTESTTOOL_VER="v$(zig_tool_version webtest-tool)"
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-aarch64" mtk webtest-tool
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-aarch64" hnd_v8 webtest-tool
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-aarch64" ipq64 webtest-tool
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-armv7a" ipq32 webtest-tool
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-armv7hf" hnd webtest-tool
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-armv7a" qca webtest-tool
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtest-tool-${WEBTESTTOOL_VER}-linux-armv5te" arm webtest-tool
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-aarch64" mtk webtestctl
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-aarch64" hnd_v8 webtestctl
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-aarch64" ipq64 webtestctl
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-armv7a" ipq32 webtestctl
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-armv7hf" hnd webtestctl
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-armv7a" qca webtestctl
	verify_zig_copy "${CURR_PATH}/binaries/webtest-tool/webtestctl-${WEBTESTTOOL_VER}-linux-armv5te" arm webtestctl

	return ${missing}
}

write_fork_manifest(){
	local platform="$1" pkgtype="$2" release_type="$3" stage="$4" source_commit
	source_commit="$(git -C "${FSS_SOURCE_ROOT:-$CURR_PATH}" rev-parse HEAD)" || return 1
	jq -n --arg base_version "$VERSION" --arg source_commit "$source_commit" \
		--arg platform "$platform/$pkgtype" --arg package_type "$pkgtype" --arg release_type "$release_type" \
		'{build:($base_version+"-personal."+($source_commit[0:12])+"-"+($platform|gsub("/";"-"))+"-"+$release_type),
		  base_version:$base_version,source_commit:$source_commit,platform:$platform,
		  package_type:$package_type,release_type:$release_type}' > "$stage/ss/fork-build.json" || return 1
}

stage_anytls_and_airport_dns(){
	local platform="$1" pkgtype="$2" client=""
	local stage="$3" name
	for name in airport-node-dns.sh airport-node-dns-boot.sh airport-node-dns-status.sh; do
		install -m 755 "${CURR_PATH}/integrations/airport-node-dns/$name" "$stage/scripts/$name" || return 1
	done
	[ "$pkgtype" = full ] || return 0
	case "$platform" in
		arm) client=fss-anytls-client-armv5 ;;
		hnd|qca|ipq32) client=fss-anytls-client-hnd ;;
		hnd_v8|mtk|ipq64) client=fss-anytls-client-arm64 ;;
		*) return 1 ;;
	esac
	install -m 755 "${FSS_ANYTLS_BUILD_OUT}/$client" "$stage/bin/fss-anytls-client" || return 1
	# Linux 2.6 ARM firmware still needs the legacy backend.
	if [ "$platform" = arm ]; then
		[ -x "$stage/bin/anytls-zig" ] || return 1
	else
		rm -f "$stage/bin/anytls-zig" || return 1
	fi
	for name in LICENSE LICENSE.x-sys NOTICE; do
		install -m 644 "${CURR_PATH}/tool/fss-anytls-client/$name" "$stage/ss/fss-anytls-$name" || return 1
	done
}

gen_folder(){
	local platform=$1
	local pkgtype=$2
	local release_type=$3
	local pkg_exta="_debug"
	cd ${CURR_PATH}
	rm -rf shadowsocks
	cp -rf fancyss shadowsocks
	# ssLinks dedicated API is not ready yet; keep the UI/helper code in source,
	# but do not ship the login backend in release packages for now.
	rm -rf ./shadowsocks/scripts/sslinks_login.sh

	# different platform	
	if [ "${platform}" == "hnd" ];then
		rm -rf ./shadowsocks/bin-arm
		rm -rf ./shadowsocks/bin-hnd_v8
		rm -rf ./shadowsocks/bin-qca
		rm -rf ./shadowsocks/bin-mtk
		rm -rf ./shadowsocks/bin-ipq32
		rm -rf ./shadowsocks/bin-ipq64
		mv ./shadowsocks/bin-hnd ./shadowsocks/bin
		rm -rf ./shadowsocks/bin/uredir
		echo hnd > ./shadowsocks/.valid
	fi
	if [ "${platform}" == "hnd_v8" ];then
		rm -rf ./shadowsocks/bin-arm
		rm -rf ./shadowsocks/bin-hnd
		rm -rf ./shadowsocks/bin-qca
		rm -rf ./shadowsocks/bin-mtk
		rm -rf ./shadowsocks/bin-ipq32
		rm -rf ./shadowsocks/bin-ipq64
		mv ./shadowsocks/bin-hnd_v8 ./shadowsocks/bin
		rm -rf ./shadowsocks/bin/uredir
		echo hnd_v8 > ./shadowsocks/.valid
	fi
	if [ "${platform}" == "qca" ];then
		rm -rf ./shadowsocks/bin-arm
		rm -rf ./shadowsocks/bin-hnd
		rm -rf ./shadowsocks/bin-hnd_v8
		rm -rf ./shadowsocks/bin-mtk
		rm -rf ./shadowsocks/bin-ipq32
		rm -rf ./shadowsocks/bin-ipq64
		mv ./shadowsocks/bin-qca ./shadowsocks/bin
		rm -rf ./shadowsocks/bin/uredir
		echo qca > ./shadowsocks/.valid
	fi
	if [ "${platform}" == "arm" ];then
		rm -rf ./shadowsocks/bin-hnd
		rm -rf ./shadowsocks/bin-hnd_v8
		rm -rf ./shadowsocks/bin-qca
		rm -rf ./shadowsocks/bin-mtk
		rm -rf ./shadowsocks/bin-ipq32
		rm -rf ./shadowsocks/bin-ipq64
		mv ./shadowsocks/bin-arm ./shadowsocks/bin
		echo arm > ./shadowsocks/.valid
		sed -i '/fancyss-hnd/d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i '/ss_basic_mcore/d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i '/ss_basic_tfo/d' ./shadowsocks/webs/Module_shadowsocks.asp
	fi
	if [ "${platform}" == "mtk" ];then
		rm -rf ./shadowsocks/bin-arm
		rm -rf ./shadowsocks/bin-hnd
		rm -rf ./shadowsocks/bin-hnd_v8
		rm -rf ./shadowsocks/bin-qca
		rm -rf ./shadowsocks/bin-ipq32
		rm -rf ./shadowsocks/bin-ipq64
		mv ./shadowsocks/bin-mtk ./shadowsocks/bin
		rm -rf ./shadowsocks/bin/uredir
		rm -rf ./shadowsocks/bin/README.md
		echo mtk > ./shadowsocks/.valid
	fi
	if [ "${platform}" == "ipq32" ];then
		rm -rf ./shadowsocks/bin-arm
		rm -rf ./shadowsocks/bin-hnd
		rm -rf ./shadowsocks/bin-hnd_v8
		rm -rf ./shadowsocks/bin-qca
		rm -rf ./shadowsocks/bin-mtk
		rm -rf ./shadowsocks/bin-ipq64
		mv ./shadowsocks/bin-ipq32 ./shadowsocks/bin
		rm -rf ./shadowsocks/bin/uredir
		rm -rf ./shadowsocks/bin/README.md
		# bd4 already include jq and curl with proxy support
		rm -rf ./shadowsocks/bin/jq
		rm -rf ./shadowsocks/bin/curl-fancyss
		# bd4 jffs2 space to small, use xray run ss
		echo ipq32 > ./shadowsocks/.valid
	fi
	if [ "${platform}" == "ipq64" ];then
		rm -rf ./shadowsocks/bin-arm
		rm -rf ./shadowsocks/bin-hnd
		rm -rf ./shadowsocks/bin-hnd_v8
		rm -rf ./shadowsocks/bin-qca
		rm -rf ./shadowsocks/bin-ipq32
		rm -rf ./shadowsocks/bin-ipq64
		mv ./shadowsocks/bin-mtk ./shadowsocks/bin
		rm -rf ./shadowsocks/bin/uredir
		rm -rf ./shadowsocks/bin/README.md
		# tuf-be6500 already include jq and curl with proxy support
		rm -rf ./shadowsocks/bin/jq
		rm -rf ./shadowsocks/bin/curl-fancyss
		echo ipq64 > ./shadowsocks/.valid
	fi
	
	# remove some binary because it's not default provide by install packages
	# find ./shadowsocks/bin -name "tuic-client" | xargs rm -rf
	# find ./shadowsocks/bin -name "naive" | xargs rm -rf

	# use debug version of chinadns-ng for aarch64 platform
	# if [ "${platform}" == "hnd_v8" -o "${platform}" == "mtk" -o "${platform}" == "ipq64" ];then
	# 	if [ "${pkgtype}" == "full" -a "${release_type}" == "debug" ];then
	# 		cp -rf ${CURR_PATH}/binaries/chinadns-ng/chinadns-ng+wolfssl@aarch64-linux-musl@generic+v8a@debug ./shadowsocks/bin/chinadns-ng
	# 	fi
	# fi
	
	# wirte type string
	if [ "${release_type}" != "debug" ];then
		pkg_exta=""
	fi
	set_pkg_web_meta ./shadowsocks/webs/Module_shadowsocks.asp "fancyss" "${platform}" "${pkgtype}" "${pkg_exta}"
	
	if [ "${pkgtype}" == "full" ];then
		# remove marked comment
		sed -i 's/#@//g' ./shadowsocks/scripts/ss_proc_status.sh
		sed -i 's/#@//g' ./shadowsocks/scripts/ss_conf.sh
	elif [ "${pkgtype}" == "lite" ];then
		# remove binaries
		rm -rf ./shadowsocks/bin/naive
		rm -rf ./shadowsocks/bin/tuic-client
		rm -rf ./shadowsocks/bin/anytls-zig
		rm -rf ./shadowsocks/bin/ipt2socks
		rm -rf ./shadowsocks/bin/haveged

		# remove scripts
		rm -rf ./shadowsocks/scripts/ss_v2ray.sh
		# remove rules
		rm -rf ./shadowsocks/ss/rules/chn.acl
		rm -rf ./shadowsocks/ss/rules/gfwlist.acl
		# remove line
		sed -i '/fancyss-full/d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i '/fancyss-full/d' ./shadowsocks/res/ss-menu.js
		sed -i '/fancyss-dns/d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i '/naiveproxy/d' ./shadowsocks/res/ss-menu.js
		sed -i '/naiveproxy/d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/，比如NaïveProxy\/AnyTLS节点//g' ./shadowsocks/res/ss-menu.js
		sed -i '/NaïveProxy\/AnyTLS由于自身特性/d' ./shadowsocks/res/ss-menu.js
		sed -i '/tuic/d' ./shadowsocks/res/ss-menu.js
		# remove lines bewteen matchs
		sed -i '/fancyss_full_1/,/fancyss_full_2/d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i '/fancyss_naive_1/,/fancyss_naive_2/d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i '/fancyss_tuic_1/,/fancyss_tuic_2/d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i '/fancyss_anytls_1/,/fancyss_anytls_2/d' ./shadowsocks/webs/Module_shadowsocks.asp
		# remove strings from page
		sed -i '/proto-anytls/d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_prot"[[:space:]]*:[[:space:]]*"[^"]*"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_server"[[:space:]]*:[[:space:]]*"[^"]*"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_port"[[:space:]]*:[[:space:]]*"[^"]*"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_user"[[:space:]]*:[[:space:]]*"[^"]*"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_pass"[[:space:]]*:[[:space:]]*"[^"]*"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_json"[[:space:]]*:[[:space:]]*"[^"]*"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"tuic_json"[[:space:]]*:[[:space:]]*"[^"]*"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"anytls_ai"[[:space:]]*:[[:space:]]*"[^"]*"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i '/^[[:space:]]*"9"[[:space:]]*:[[:space:]]*.*anytls_/d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_prot"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_server"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_port"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_user"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_pass"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"naive_json"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"tuic_json"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"anytls_server"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"anytls_port"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"anytls_pass"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"anytls_sni"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/,[[:space:]]*"anytls_ai"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i '/^[[:space:]]*"anytls_server"[[:space:]]*:/d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/、anytls:\/\/ 等链接/ 等链接/g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/\,\s\"ss_basic_vcore\"//g' ./shadowsocks/webs/Module_shadowsocks.asp
		# modify words
		# trojan 用xray运行，所以trojan多核心功能删除
		sed -i 's/ss\/ssr\/trojan/ss\/ssr/g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/的科学上网工具。/九种协议的科学上网工具。/g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/九种协议/六种协议/g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/科学上网工具/科学上网、游戏加速工具/g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/11\.111/16.667/g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/\s\&\&\s\!\snaive_on//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/shadowsocks_2/shadowsocks_lite_2/g' ./shadowsocks/res/ss-menu.js
		sed -i 's/config\.json\.js/config_lite\.json\.js/g' ./shadowsocks/res/ss-menu.js
	fi

	if [ "${release_type}" == "release" ];then
		# 移除注释
		# remove match words: //fancyss-full //fancyss-full_1 //fancyss-full_2
		sed -i 's/[ \t]*\/\/fancyss-full//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/[ \t]*\/\/fancyss-full//g' ./shadowsocks/res/ss-menu.js

		# remove match words: <!--fancyss-full-->
		sed -i 's/[ \t]*<!--fancyss-full-->//g' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i 's/[ \t]*<!--fancyss-full-->//g' ./shadowsocks/res/ss-menu.js

		# remove line contain: <!--fancyss_full_1--> <!--fancyss_full_1-->
		sed -i 's/[ \t]*<!--fancyss_full_[1-2]-->//g' ./shadowsocks/webs/Module_shadowsocks.asp
		
		# remove line start of: //
		sed -i '/^[ \t]*\/\//d' ./shadowsocks/webs/Module_shadowsocks.asp
		sed -i '/^[ \t]*\/\//d' ./shadowsocks/res/ss-menu.js

		# remove line <!-- ?? -->
		sed -i 's/<!--.*-->//g' ./shadowsocks/webs/Module_shadowsocks.asp

		# remove empty line
		sed -i '/^[[:space:]]*$/d' ./shadowsocks/webs/Module_shadowsocks.asp

		# icon
		rm -rf ./shadowsocks/res/icon-shadowsocks_debug.png
	else
		mv -f ./shadowsocks/res/icon-shadowsocks_debug.png ./shadowsocks/res/icon-shadowsocks.png
	fi

	# 有些功能还没准备好，先去掉
	# 1. 广告过滤规则
	# rm -rf ./shadowsocks/bin/smartdns
	rm -rf ./shadowsocks/ss/rules/adslist.gz
	# rm -rf ./shadowsocks/ss/rules/smartdns_smrt*
	stage_anytls_and_airport_dns "$platform" "$pkgtype" ./shadowsocks || return 1
	write_fork_manifest "$platform" "$pkgtype" "$release_type" ./shadowsocks || return 1
	# sed -i '/fancyss_todo/d' ./shadowsocks/webs/Module_shadowsocks.asp
}

build_pkg() {
	local platform=$1
	local pkgtype=$2
	local release_type=$3
	# different platform
	if [ ${release_type} == "release" ];then
		echo "打包：fancyss_${platform}_${pkgtype}.tar.gz"
		tar -zcf ${PACKAGES_DIR}/fancyss_${platform}_${pkgtype}.tar.gz shadowsocks >/dev/null || return 1
		md5value=$(md5sum ${PACKAGES_DIR}/fancyss_${platform}_${pkgtype}.tar.gz|tr " " "\n"|sed -n 1p)
		cat >>${PACKAGES_DIR}/version_tmp.json.js <<-EOF
			,"md5_${platform}_${pkgtype}":"${md5value}"
		EOF
	elif [ ${release_type} == "debug" ];then
		echo "打包：fancyss_${platform}_${pkgtype}_${release_type}.tar.gz"
		tar -zcf ${PACKAGES_DIR}/fancyss_${platform}_${pkgtype}_${release_type}.tar.gz shadowsocks >/dev/null || return 1
	fi
}


papare(){
	cp_rules
	prepare_geodata_assets
	cp_rules_ng2
	sync_binary
	verify_zig_tool_binaries || exit 1
	cat >${PACKAGES_DIR}/version_tmp.json.js <<-EOF
	{
	"name":"fancyss"
	,"version":"${VERSION}"
	EOF
}

finish(){
	echo "}" >>${PACKAGES_DIR}/version_tmp.json.js
	cat ${PACKAGES_DIR}/version_tmp.json.js | jq '.' >${PACKAGES_DIR}/version.json.js
	rm -rf ${PACKAGES_DIR}/version_tmp.json.js
}

pack(){
	gen_folder "$1" "$2" "$3" || exit 1
	build_pkg "$1" "$2" "$3" || exit 1
	rm -rf ${CURR_PATH}/shadowsocks/
}

check_build_inputs(){
	local tool prefix version target
	for tool in geotool node-tool sub-tool xapi-tool ws-tool status-tool webtest-tool; do
		version="$(zig_tool_version "$tool")" || return 1
		prefix="$tool"
		[ "$tool" != ws-tool ] || prefix=websocketd
		for target in aarch64 armv7a armv7hf; do
			[ -s "$CURR_PATH/binaries/$prefix/$prefix-v$version-linux-$target" ] &&
				[ -x "$CURR_PATH/binaries/$prefix/$prefix-v$version-linux-$target" ] || {
				echo "Missing build input: $prefix-v$version-linux-$target" >&2
				return 1
			}
		done
		if [ "$tool" != xapi-tool ]; then
			[ -s "$CURR_PATH/binaries/$prefix/$prefix-v$version-linux-armv5te" ] || return 1
		fi
		(cd "$CURR_PATH/binaries/$prefix" && sha256sum -c "SHA256SUMS-v$version") || return 1
	done
}

publish_packages(){
	local destination="${FSS_PACKAGE_DEST:-$CURR_PATH/packages}"
	local previous="${destination}.previous.$$"
	# Docker builds run as root; the publishing host must be able to read the output.
	chmod 755 "$PACKAGES_DIR" || return 1
	PREVIOUS_PACKAGES="$previous"
	if [ -e "$destination" ]; then mv "$destination" "$previous"; fi
	if mv "$PACKAGES_DIR" "$destination"; then
		rm -rf "$previous"
		PACKAGES_DIR="$destination"
	else
		[ ! -d "$previous" ] || mv "$previous" "$destination"
		return 1
	fi
	echo "完成！生成的离线安装包在：${PACKAGES_DIR}"
}

cleanup_package_build(){
	if [ -n "${PREVIOUS_PACKAGES:-}" ] && [ -d "$PREVIOUS_PACKAGES" ] && [ ! -e "${FSS_PACKAGE_DEST:-$CURR_PATH/packages}" ]; then
		mv "$PREVIOUS_PACKAGES" "${FSS_PACKAGE_DEST:-$CURR_PATH/packages}"
	fi
	if [ "$owned_client_out" = 1 ]; then
		rm -rf "$FSS_ANYTLS_BUILD_OUT"
	fi
	if [ "$PACKAGES_DIR" != "${FSS_PACKAGE_DEST:-$CURR_PATH/packages}" ]; then
		rm -rf "$PACKAGES_DIR"
	fi
	rmdir "$CURR_PATH/.fss-build.lock"
}

make_internal(){
	check_build_inputs || exit 1
	mkdir "$CURR_PATH/.fss-build.lock" || { echo "A package build is already running" >&2; exit 1; }
	local output_parent
	output_parent="$(dirname "${FSS_PACKAGE_DEST:-$CURR_PATH/packages}")"
	PACKAGES_DIR="$(mktemp -d "$output_parent/.packages.XXXXXX")"
	owned_client_out=0
	if [ -z "${FSS_ANYTLS_BUILD_OUT:-}" ]; then
		FSS_ANYTLS_BUILD_OUT="$(mktemp -d)" || exit 1
		owned_client_out=1
	fi
	export FSS_ANYTLS_BUILD_OUT
	trap cleanup_package_build EXIT
	local arch
	for arch in armv5 armv7 arm64; do
		/bin/sh "${CURR_PATH}/scripts/build_anytls_client.sh" "$arch" || exit 1
	done
	papare
	# --- for release ---
	pack hnd full release
	pack hnd lite release
	pack hnd_v8 full release
	pack hnd_v8 lite release
	pack qca full release
	pack qca lite release
	pack arm full release
	pack arm lite release
	pack mtk full release
	pack mtk lite release
	pack ipq32 full release
	pack ipq32 lite release
	pack ipq64 full release
	pack ipq64 lite release
	# --- for debug ---
	pack hnd full debug
	pack hnd_v8 full debug
	pack qca full debug
	pack arm full debug
	pack mtk full debug
	pack ipq32 full debug
	pack ipq64 full debug
	finish
	python3 "$CURR_PATH/scripts/write_release_metadata.py" "$PACKAGES_DIR" "${FSS_SOURCE_ROOT:-$CURR_PATH}"
	python3 "$CURR_PATH/scripts/verify_packages.py" "$PACKAGES_DIR"
	publish_packages
}

make(){
    if [ "${FSS_INTERNAL_BUILD:-0}" = 1 ]; then
        make_internal
    else
        python3 "$CURR_PATH/scripts/package_build.py" "$@"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    make "$@"
fi
