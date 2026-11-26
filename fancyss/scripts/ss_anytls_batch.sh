#!/bin/sh

fss_anytls_mem_mib() { awk '/^MemAvailable:/ {print int($2/1024); exit}' /proc/meminfo; }
fss_anytls_uptime() { awk '{print $1; exit}' /proc/uptime; }

fss_anytls_batch_shunt_idle() {
	(flock -n 7) 7>>/var/lock/koolss.lock
}
fss_anytls_batch_state() {
	local phase="$1" reason="$2" events="$3" tmp="/tmp/upload/anytls-webtest.json.$$"
	[ -f "${events}" ] || events=/dev/null
	jq -s --arg phase "${phase}" --arg reason "${reason}" --argjson concurrency "${WT_ANYTLS_AUTO_LIMIT}" \
		--argjson total "${WT_ANYTLS_AUTO_COUNT}" '
		reduce (.[] | select(.id != null)) as $event ({}; .[$event.id|tostring]=$event.state)
		| {completed:(map(select(.!="testing"))|length),
			running:(if $phase=="running" then map(select(.=="testing"))|length else 0 end),
			timeouts:(map(select(.=="timeout"))|length),$phase,$reason,$concurrency,$total}
	' "${events}" > "${tmp}" 2>/dev/null && mv -f "${tmp}" /tmp/upload/anytls-webtest.json
	rm -f "${tmp}"
}

fss_anytls_batch_begin() {
	local targets="$1" client="$2" now mem profile
	WT_ANYTLS_AUTO_PROFILE="${KSROOT}/configs/fancyss/anytls-webtest-profile.json"
	WT_ANYTLS_AUTO_KEY="$({
		cut -d '|' -f 1 "${targets}"
		printf '%s\n' "${ss_basic_furl}"
		uname -r
		nvram get firmver
		nvram get buildno
		nvram get extendno
		sha256sum "${client}" "$(wt_pick_webtest_tool)" | awk '{print $1}'
	} | sha256sum | awk '{print $1}')"
	WT_ANYTLS_AUTO_COUNT="$(wc -l < "${targets}" | tr -d ' ')"
	profile="$(jq -ec --arg key "${WT_ANYTLS_AUTO_KEY}" '
		select(.key==$key and .level>=1 and .level<=65535 and (.level%1)==0 and
			([.samples,.sum,.timeouts,.trial_count,.trial_sum,.cooldown] | all(type=="number" and .>=0)))
		| .trial_timeouts //= (if .trial_count>0 then .timeouts else 0 end)
	' "${WT_ANYTLS_AUTO_PROFILE}" 2>/dev/null)" || profile=""
	if [ -z "${profile}" ]; then
		profile="$(jq -nc --arg key "${WT_ANYTLS_AUTO_KEY}" '{$key,level:1,samples:0,sum:0,timeouts:0,trial_count:0,trial_sum:0,trial_timeouts:0,cooldown:0}')"
	fi
	WT_ANYTLS_AUTO_PREVIOUS="${profile}"
	WT_ANYTLS_AUTO_LIMIT="$(printf '%s' "${profile}" | jq -r '.level')"
	WT_ANYTLS_AUTO_REASON=""
	mem="$(fss_anytls_mem_mib)"
	now="$(date +%s)"
	case "${mem}" in ''|*[!0-9]*) mem=0 ;; esac
	if [ "${mem}" -lt 48 ]; then
		WT_ANYTLS_AUTO_REASON=memory_pressure
		fss_anytls_batch_state canceled "${WT_ANYTLS_AUTO_REASON}" /dev/null
		return 1
	fi
	if [ "${WT_ANYTLS_AUTO_LIMIT}" -gt "${WT_ANYTLS_AUTO_COUNT}" ]; then
		WT_ANYTLS_AUTO_LIMIT="${WT_ANYTLS_AUTO_COUNT}"
	fi
	if [ "${FSS_WEBTEST_MANUAL:-}" = 1 ] &&
		[ "${WT_ANYTLS_AUTO_LIMIT}" -lt "${WT_ANYTLS_AUTO_COUNT}" ] &&
		printf '%s' "${profile}" | jq -e --argjson now "${now}" '.samples>=2 and .cooldown<=$now' >/dev/null; then
		if [ "${mem}" -lt 64 ]; then
			WT_ANYTLS_AUTO_REASON=low_headroom
		elif ! fss_anytls_batch_shunt_idle; then
			WT_ANYTLS_AUTO_REASON=shunt_busy
		else
			WT_ANYTLS_AUTO_LIMIT=$((WT_ANYTLS_AUTO_LIMIT + 1))
			WT_ANYTLS_AUTO_REASON=trial
		fi
	fi
	WT_ANYTLS_AUTO_MIN="${mem}"
	WT_ANYTLS_AUTO_START="$(fss_anytls_uptime)"
	fss_anytls_batch_state running "${WT_ANYTLS_AUTO_REASON}" /dev/null
}

fss_anytls_batch_wait() {
	local pid="$1" timeout="$2" events="$3" mem elapsed=0 updates=0 start now
	start="$(fss_anytls_uptime)"
	while kill -0 "${pid}" 2>/dev/null; do
		mem="$(fss_anytls_mem_mib)"
		case "${mem}" in ''|*[!0-9]*) mem=0 ;; esac
		[ "${mem}" -ge "${WT_ANYTLS_AUTO_MIN}" ] || WT_ANYTLS_AUTO_MIN="${mem}"
		if [ "${mem}" -lt 48 ]; then
			WT_ANYTLS_AUTO_REASON=memory_pressure
			printf '%s\n' memory_pressure > "${WT_WEBTEST_STOP_FLAG}"
			return 2
		fi
		if [ "${updates}" -eq 0 ]; then
			fss_anytls_batch_state running "${WT_ANYTLS_AUTO_REASON}" "${events}"
			now="$(fss_anytls_uptime)"
			elapsed="$(awk -v end="${now}" -v start="${start}" 'BEGIN {print int(end-start)}')"
			[ "${elapsed}" -lt "${timeout}" ] || return 1
		fi
		updates=$(((updates + 1) % 4))
		usleep 250000
	done
}

fss_anytls_batch_finish() (
	umask 077
	local events="$1" outcome="$2" now end seconds result done_count timeouts ok profile phase=complete
	[ -f "${events}" ] || events=/dev/null
	result="$(jq -sr '
		reduce (.[] | select(.id != null and .state != "testing")) as $e ({}; .[$e.id|tostring]=$e.state)
		| [length, (map(select(.=="timeout"))|length), (map(select(.=="ok"))|length)] | @tsv
	' "${events}" 2>/dev/null)" || result="0 0 0"
	set -- ${result}
	done_count="$1" timeouts="$2" ok="$3"
	[ "${outcome}" = 0 ] || phase=failed
	[ "${WT_ANYTLS_AUTO_REASON}" != memory_pressure ] || phase=canceled
	now="$(date +%s)"
	end="$(fss_anytls_uptime)"
	seconds="$(awk -v end="${end}" -v start="${WT_ANYTLS_AUTO_START}" 'BEGIN{printf "%.3f",end-start}')"
	profile="$(printf '%s' "${WT_ANYTLS_AUTO_PREVIOUS}" | jq -c \
		--arg reason "${WT_ANYTLS_AUTO_REASON}" --argjson now "${now}" --argjson n "${WT_ANYTLS_AUTO_LIMIT}" \
		--argjson elapsed "${seconds}" --argjson minimum "${WT_ANYTLS_AUTO_MIN}" \
		--argjson timeouts "${timeouts}" --argjson completed "${done_count}" \
		--argjson total "${WT_ANYTLS_AUTO_COUNT}" --argjson rc "${outcome}" --argjson ok "${ok}" '
		def complete: $rc==0 and $minimum>=56 and $completed==$total and ($ok+$timeouts)==$total;
		def reset_trial: .trial_count=0 | .trial_sum=0 | .trial_timeouts=0;
		if $reason=="memory_pressure" then
			.level=([1,$n-1]|max) | .samples=0 | .sum=0 | .timeouts=0
			| reset_trial | .cooldown=$now+86400
		elif $reason=="trial" then
			if (complete|not) or $timeouts>.timeouts then
				reset_trial | .cooldown=$now+86400
			else .trial_count+=1 | .trial_sum+=$elapsed | .trial_timeouts=([(.trial_timeouts // 0),$timeouts]|max)
				| if .trial_count<2 then .
				  elif .trial_sum/2 <= (.sum/.samples)*0.95 then
					.level=$n | .samples=2 | .sum=.trial_sum | .timeouts=.trial_timeouts | reset_trial
				  else reset_trial | .cooldown=$now+86400 end
			end
		elif $n==.level and .samples<2 and complete then
			.samples+=1 | .sum+=$elapsed | .timeouts=([.timeouts,$timeouts]|max)
		else . end
	')" || { fss_anytls_batch_state "${phase}" "${WT_ANYTLS_AUTO_REASON}" "${events}"; return 1; }
	if [ "${WT_ANYTLS_AUTO_REASON}" = trial ] &&
		printf '%s' "${profile}" | jq -e --argjson now "${now}" '.cooldown>$now' >/dev/null; then
		WT_ANYTLS_AUTO_REASON=trial_rejected
	fi
	fss_anytls_batch_state "${phase}" "${WT_ANYTLS_AUTO_REASON}" "${events}"
	[ "${profile}" != "${WT_ANYTLS_AUTO_PREVIOUS}" ] || return 0
	printf '%s\n' "${profile}" > "${WT_ANYTLS_AUTO_PROFILE}.$$" && mv -f "${WT_ANYTLS_AUTO_PROFILE}.$$" "${WT_ANYTLS_AUTO_PROFILE}"
)

fss_anytls_batch_recover_results() {
	local events="$1" records
	records="$(jq -sr '
		reduce (.[]|select(.id != null and .state != "testing")) as $e ({}; .[$e.id|tostring]=$e)
		| to_entries[] | [.key, (if .value.state=="ok" then .value.latency_ms else .value.state end|tostring)] | join(">")
	' "${events}" 2>/dev/null)" || return 0
	printf '%s\n' "${records}" | while IFS='>' read -r id result; do
		[ -z "${id}" ] || wt_set_batch_state "${id}" "${result}"
	done
}

fss_anytls_batch_mark_stopped() {
	local json=/tmp/upload/anytls-webtest.json
	[ -f "$1" ] || return 0
	WT_ANYTLS_AUTO_LIMIT="$(jq -er 'select(.phase=="running")|.concurrency' "${json}" 2>/dev/null)" || return 0
	WT_ANYTLS_AUTO_COUNT="$(jq -er '.total' "${json}" 2>/dev/null)" || return 0
	fss_anytls_batch_state canceled user_stopped "$1"
}
