#!/bin/sh

# fancyss script for asuswrt/merlin based router with software center

source /koolshare/scripts/base.sh
ss_basic_enable=$(dbus get ss_basic_enable)
LOCK_FILE=/var/lock/fancyss.lock
SCHEMA2_POSTSAVE_IDS_KEY="fss_node_postsave_ids"

set_lock(){
	exec 1000>"${LOCK_FILE}" || exit 1
	flock "${1:--n}" 1000 || {
		# bring back to original log
		http_response "$ACTION"
		# echo_date "$BASH $ARGS" | tee -a ${LOG_FILE}
		exit 1
	}
}

unset_lock() {
	flock -u 1000
	exec 1000>&-
}

stop_fancyss(){
	/bin/sh /koolshare/ss/ssconfig.sh stop
}

pre_start(){
	local postsave_ids=""
	postsave_ids="$(dbus get ${SCHEMA2_POSTSAVE_IDS_KEY})"
	if [ -n "${postsave_ids}" ] && [ -x "/koolshare/scripts/ss_node_postsave.sh" ];then
		/bin/sh /koolshare/scripts/ss_node_postsave.sh rebuild "${postsave_ids}" >/dev/null 2>&1 || true
		dbus remove ${SCHEMA2_POSTSAVE_IDS_KEY}
	fi
}

start_fancyss(){
	/bin/sh /koolshare/ss/ssconfig.sh restart
}

start_fancyss_shunt_hot(){
	if [ "$(dbus get ss_basic_shunt_hot_reload)" = "1" ] && [ -x "/koolshare/scripts/ss_shunt_hot_reload.sh" ]; then
		echo_date "[hot-reload] 尝试通过 Xray API 热更新节点分流规则..."
		if /bin/sh /koolshare/scripts/ss_shunt_hot_reload.sh apply; then
			return 0
		fi
		echo_date "[hot-reload] 热更新失败，回退到完整重启。"
		FSS_SHUNT_FORCE_RESTART=1 start_fancyss
		return
	fi
	start_fancyss
}

# call by ws
case $1 in
start)
	set_lock
	true > /tmp/upload/ss_log.txt
	pre_start
	rc=0
	(set -o pipefail; start_fancyss 2>&1 | tee -a /tmp/upload/ss_log.txt) || rc=$?
	echo XU6J03M6 | tee -a /tmp/upload/ss_log.txt
	unset_lock
	exit "${rc}"
	;;
start_shunt_hot)
	set_lock
	true > /tmp/upload/ss_log.txt
	pre_start
	rc=0
	(set -o pipefail; start_fancyss_shunt_hot 2>&1 | tee -a /tmp/upload/ss_log.txt) || rc=$?
	echo XU6J03M6 | tee -a /tmp/upload/ss_log.txt
	unset_lock
	exit "${rc}"
	;;
start_by_ws)
	set_lock
	true > /tmp/upload/ss_log.txt
	pre_start
	rc=0
	(set -o pipefail; start_fancyss 2>&1 | tee -a /tmp/upload/ss_log.txt) || rc=$?
	echo XU6J03M6 | tee -a /tmp/upload/ss_log.txt
	unset_lock
	exit "${rc}"
	;;
stop)
	set_lock -x
	true > /tmp/upload/ss_log.txt
	rc=0
	(set -o pipefail; stop_fancyss 2>&1 | tee -a /tmp/upload/ss_log.txt) || rc=$?
	echo XU6J03M6 | tee -a /tmp/upload/ss_log.txt
	unset_lock
	exit "${rc}"
	;;
test)
	sleep 100
	;;
esac

# call by httpdb
case $2 in
start)
	set_lock
	true > /tmp/upload/ss_log.txt
	http_response "$1"
	pre_start
	rc=0
	(set -o pipefail; start_fancyss 2>&1 | tee -a /tmp/upload/ss_log.txt) || rc=$?
	echo XU6J03M6 | tee -a /tmp/upload/ss_log.txt
	unset_lock
	exit "${rc}"
	;;
start_shunt_hot)
	set_lock
	true > /tmp/upload/ss_log.txt
	http_response "$1"
	pre_start
	rc=0
	(set -o pipefail; start_fancyss_shunt_hot 2>&1 | tee -a /tmp/upload/ss_log.txt) || rc=$?
	echo XU6J03M6 | tee -a /tmp/upload/ss_log.txt
	unset_lock
	exit "${rc}"
	;;
start_by_ws)
	set_lock
	true > /tmp/upload/ss_log.txt
	pre_start
	rc=0
	(set -o pipefail; start_fancyss 2>&1 | tee -a /tmp/upload/ss_log.txt) || rc=$?
	echo XU6J03M6 | tee -a /tmp/upload/ss_log.txt
	unset_lock
	exit "${rc}"
	;;
stop)
	set_lock -x
	true > /tmp/upload/ss_log.txt
	http_response "$1"
	rc=0
	(set -o pipefail; stop_fancyss 2>&1 | tee -a /tmp/upload/ss_log.txt) || rc=$?
	echo XU6J03M6 | tee -a /tmp/upload/ss_log.txt
	unset_lock
	exit "${rc}"
	;;
test)
	sleep 100
	;;
esac
