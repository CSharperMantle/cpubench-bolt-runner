#!/bin/bash
# shellcheck disable=SC1091,SC2329
# vim: set tabstop=8 shiftwidth=8 softtabstop=8 noexpandtab:
# SPDX-License-Identifier: GPL-3.0-or-later

LLVM_PATH="${1:?Usage: \[CPUBENCH_DIR=...\] \[BOLT_JOBS=...\] $0 <LLVM_PATH> \[WORK_DIR\]}"
CPUBENCH_DIR="${CPUBENCH_DIR:-"$HOME"/workspace/cpubench}"
WORK_DIR="${2:-"$CPUBENCH_DIR"/work_dir}"
BOLT_JOBS="${BOLT_JOBS:-"$(nproc)"}"

script_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

export CPUBENCH_DIR LLVM_PATH WORK_DIR

shopt -s nullglob

_handle_signal() {
	trap '' INT TERM
	echo 'XXX I harness: Interrupt received, killing children...' >&2
	kill -- -"$$" 2>/dev/null
	exit "$((128 + $1))"
}
trap '_handle_signal $(kill -l INT)' INT
trap '_handle_signal $(kill -l TERM)' TERM

restore_basic_event_header() {
	local merged="$1"
	shift
	local fragment current header=''
	local temporary

	for fragment in "$@"; do
		current="$(awk '/^no_lbr([[:space:]]|$)/ { print; found = 1; exit } END { if (!found) exit 1 }' "$fragment")" || return 1
		if [ -z "$header" ]; then
			header="$current"
		elif [ "$current" != "$header" ]; then
			printf 'incompatible basic-profile headers: %s != %s\n' \
				"$header" "$current" >&2
			return 1
		fi
	done

	[ -n "$header" ] || return 1
	temporary="$(mktemp "$merged".tmp.XXXXXX)" || return 1
	if FDATA_HEADER="$header" awk '
		BEGIN { replaced = 0 }
		/^no_lbr([[:space:]]|$)/ && !replaced {
			print ENVIRON["FDATA_HEADER"]
			replaced = 1
			next
		}
		{ print }
		END { if (!replaced) exit 1 }
	' "$merged" >"$temporary"; then
		if mv -f "$temporary" "$merged"; then
			return 0
		fi
	fi

	rm -f "$temporary"
	return 1
}

index_perf_profiles() {
	local bm tune bin_dir run_dir collect_dir profile profile_dir title log
	local command_line command list_file
	local mapped=0
	local rc=0

	find "$WORK_DIR"/benchmarks -name '*.perf1-data-list' -delete 2>/dev/null

	for tune in "${tunes[@]}"; do
		for bm in "$WORK_DIR"/benchmarks/*; do
			[ -d "$bm"/bin/"$tune"_perf1 ] || continue
			bin_dir="$(realpath "$bm"/bin/"$tune"_perf1)"
			run_dir="$bm"/run/run_"$tune"_perf1_0000
			collect_dir="$bm"/collect/bolt
			[ -d "$collect_dir" ] || continue

			for profile_dir in "$collect_dir"/*; do
				[ -d "$profile_dir" ] || continue
				title="${profile_dir##*/}"
				log="$run_dir"/"$title"_out_log
				if [ ! -f "$log" ]; then
					printf 'XXX E PROFILE-MAP: no workload log for %s\n' "$profile_dir" >&2
					rc=1
					continue
				fi

				IFS= read -r command_line <"$log" || command_line=''
				command="${command_line%% *}"
				case "$command" in
				"$bin_dir"/*)
					;;
				*)
					# For example, the Spark cases run scripts outside *_perf1/bin.
					continue
					;;
				esac

				if ! file "$command" | grep -F 'ELF' >/dev/null 2>&1; then
					continue
				fi

				profile="$profile_dir"/perf.data
				if [ ! -s "$profile" ]; then
					printf 'XXX E PROFILE-MAP: no perf.data for %s (%s)\n' "$command" "$title" >&2
					rc=1
					continue
				fi

				list_file="$command".perf1-data-list
				printf '%s\n' "$profile" >>"$list_file"
				printf 'XXX I PROFILE-MAP: %s <- %s\n' "$command" "$profile" >&2
				mapped="$((mapped + 1))"
			done
		done
	done

	if [ "$mapped" -eq 0 ]; then
		printf 'XXX E PROFILE-MAP: no native CPUBench workload profiles were mapped\n' >&2
		return 1
	fi
	return "$rc"
}

bolt_with_perf_profile() {
	shopt -s nullglob

	. ./source-bolt-flags.sh

	local f="$1"
	local dir tune orig profiled list_file profile stdout header_stdout fragment merged
	local index=0
	local -a fragments=()

	if ! file "$f" | grep -F 'ELF' >/dev/null 2>&1; then
		return 0
	fi

	dir="${f%/*}"
	tune="${dir##*/}"
	tune="${tune%_optimized}"
	orig="${dir%/*}"/"$tune"_original/"${f##*/}"
	profiled="${dir%/*}"/"$tune"_perf1/"${f##*/}"
	list_file="$profiled".perf1-data-list

	if [ ! -s "$list_file" ]; then
		printf 'XXX W harness: %s was not a directly profiled workload, skipping\n' "$f" >&2
		return 0
	fi

	while IFS= read -r profile; do
		[ -s "$profile" ] || {
			printf 'XXX E PERF2BOLT: missing profile %s for %s\n' "$profile" "$f" >&2
			return 1
		}
		fragment="$f".perf1.fdata."$index"
		if stdout="$("$LLVM_PATH"/bin/perf2bolt \
			"$orig" \
			-p "$profile" \
			-o "$fragment" \
			-ba 2>&1)"; then
			fragments+=("$fragment")
			printf 'XXX I PERF2BOLT: %s <- %s\n%s\n' "$f" "$profile" "$stdout" >>"$f".bolt-out
		else
			printf 'XXX E PERF2BOLT: %s <- %s\n%s\n' "$f" "$profile" "$stdout" >>"$f".bolt-err
			printf 'XXX E PERF2BOLT: %s\n' "$f" >&2
			rm -f "${fragments[@]}" "$fragment"
			return 1
		fi
		index="$((index + 1))"
	done <"$list_file"

	if [ "${#fragments[@]}" -eq 0 ]; then
		printf 'XXX E PERF2BOLT: no profile fragments for %s\n' "$f" >&2
		return 1
	fi

	merged="$f".prof.fdata
	if [ "${#fragments[@]}" -eq 1 ]; then
		cp -a "${fragments[0]}" "$merged" || return 1
	elif stdout="$("$LLVM_PATH"/bin/merge-fdata "${fragments[@]}" -o "$merged" 2>&1)"; then
		if ! header_stdout="$(restore_basic_event_header "$merged" "${fragments[@]}" 2>&1)"; then
			printf 'XXX E FDATA-HEADER: %s\n%s\n' "$f" "$header_stdout" >>"$f".bolt-err
			printf 'XXX E FDATA-HEADER: %s\n' "$f" >&2
			rm -f "${fragments[@]}"
			return 1
		fi
		printf 'XXX I MERGE-FDATA: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-out
	else
		printf 'XXX E MERGE-FDATA: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-err
		printf 'XXX E MERGE-FDATA: %s\n' "$f" >&2
		rm -f "${fragments[@]}"
		return 1
	fi
	rm -f "${fragments[@]}"

	printf 'XXX I BOLT: %s\n' "$f" >&2
	if stdout="$("$LLVM_PATH"/bin/llvm-bolt \
		"$orig" \
		-o "$f" \
		--data "$merged" \
		"${BOLT_FULL_FLAGS[@]}" 2>&1)"; then
		touch "$f".bolt-converted
		printf 'XXX I BOLT: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-out
		return 0
	fi

	printf 'XXX E BOLT: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-err
	printf 'XXX E BOLT: %s\n' "$f" >&2
	cp -a "$orig" "$f"
	return 1
}
export -f restore_basic_event_header bolt_with_perf_profile

find "$WORK_DIR"/benchmarks \
	-type d \
	\( \
		-path '*/bin/*_optimized' \
		-o -path '*/build/*_optimized' \
	\) \
	-prune \
	-exec rm -rf {} + 2>/dev/null
find "$WORK_DIR"/benchmarks \
	\( -name '*.bolt-*' \) \
	-delete 2>/dev/null
rm -f e.log o.log

tunes=()
declare -A seen_tunes=()
while IFS= read -r -d '' dir; do
	tune="${dir##*/}"
	tune="${tune%_original}"
	if [ -z "${seen_tunes[$tune]+x}" ]; then
		seen_tunes["$tune"]=1
		tunes+=("$tune")
	fi
done < <(find "$WORK_DIR"/benchmarks -type d -path '*/bin/*_original' -print0)
if [ "${#tunes[@]}" -eq 0 ]; then
	exit 3
fi

index_perf_profiles
rc_index=$?

rc_bolt=0
for tune in "${tunes[@]}"; do
	for bm in "$WORK_DIR"/benchmarks/*; do
		[ -d "$bm"/bin/"$tune"_original ] || continue
		rm -rf "$bm"/bin/"$tune"_optimized "$bm"/build/"$tune"_optimized
		mkdir -p "$bm"/bin/"$tune"_optimized "$bm"/build/"$tune"_optimized || exit 3
		cp -a "$bm"/bin/"$tune"_original/. "$bm"/bin/"$tune"_optimized/ || exit 3
		cp -a "$bm"/build/"$tune"_original/. "$bm"/build/"$tune"_optimized/ || exit 3
	done
	find "$WORK_DIR"/benchmarks \
		-type f \
		-executable \
		-path '*/bin/'"$tune"'_optimized/*' \
		-not \( \
			-name '*.bolt-*' \
			-o -name '*.prof.fdata*' \
			-o -name '*.stripped' \
		\) \
		-print0 |
		parallel -0 --line-buffer -j "$BOLT_JOBS" bolt_with_perf_profile {} || rc_bolt=1
done

find "$WORK_DIR"/benchmarks -name '*.bolt-err' -exec cat {} + >e.log 2>/dev/null
find "$WORK_DIR"/benchmarks -name '*.bolt-out' -exec cat {} + >o.log 2>/dev/null
find "$WORK_DIR"/benchmarks \( -name '*.bolt-err' -o -name '*.bolt-out' \) -delete 2>/dev/null

"$CPUBENCH_DIR"/cpubench.sh \
	-c "$script_dir"/config/cpubench-optimized.ini \
	-a run \
	--work_dir "$WORK_DIR"
rc_optim=$?

printf -- '---\n'
printf -- '\n'
printf -- 'Test Results\n'
printf -- '============\n'
printf -- '\n'
printf -- '\n'
printf -- 'Stages\n'
printf -- '---------\n'
printf -- '\n'
printf -- '\t%s\tBuild\n' '---'
printf -- '\t%s\tRun-original\n' '---'
printf -- '\t%s\tRun-perf1\n' '---'
printf -- '\t%s\tProfile-map\n' "$([ "$rc_index" -eq 0 ] && echo PASS || echo FAIL)"
printf -- '\t%s\tperf2bolt/BOLT\n' "$([ "$rc_bolt" -eq 0 ] && echo PASS || echo FAIL)"
printf -- '\t%s\tRun-optimized\n' "$([ "$rc_optim" -eq 0 ] && echo PASS || echo FAIL)"
printf -- '\n'
printf -- '\n'
printf -- 'Notable entries in e.log\n'
printf -- '------------------------\n'
printf -- '\n'
if [ -s e.log ]; then
	grep -E '^XXX (W|E) (harness|BOLT|PERF2BOLT|FDATA-HEADER):' e.log |
		while IFS= read -r line; do
			printf '\t%s\n' "$line"
		done
fi
printf -- '\n'
printf -- '---\n'

exit "$((rc_index | rc_bolt | rc_optim))"
