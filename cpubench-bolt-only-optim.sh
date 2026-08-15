#!/bin/bash
# shellcheck disable=SC2329
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
	exit $((128 + $1))
}
trap '_handle_signal $(kill -l INT)' INT
trap '_handle_signal $(kill -l TERM)' TERM

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

bolt_with_profile() {
	shopt -s nullglob

	. ./source-bolt-flags.sh

	local dir tune orig instr stdout
	local -a profiles
	local f="$1"
	if ! file "$f" | grep -F 'ELF' >/dev/null 2>&1; then
		return 0
	fi
	dir="${f%/*}"
	tune="${dir##*/}"
	tune="${tune%_optimized}"
	orig="${dir%/*}"/"$tune"_original/"${f##*/}"
	instr="${dir%/*}"/"$tune"_instrumented/"${f##*/}"
	if [ ! -e "$instr".bolt-instr ]; then
		printf 'XXX W harness: %s was not instrumented, skipping\n' "$f" >&2
		return 0
	fi
	profiles=("$instr".prof.fdata.*)
	if [ "${#profiles[@]}" -eq 0 ]; then
		printf 'XXX W harness: %s has no instrumentation profile, skipping\n' "$f" >&2
		return 0
	fi
	if stdout="$("$LLVM_PATH"/bin/merge-fdata "${profiles[@]}" -o "$f".prof.fdata 2>&1)"; then
		touch "$f".bolt-fdata-merged
	else
		printf 'XXX E MERGE-FDATA: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-err
		printf 'XXX E MERGE-FDATA: %s\n' "$f" >&2
		return 1
	fi
	printf 'XXX I BOLT: %s\n' "$f" >&2
	if stdout="$("$LLVM_PATH"/bin/llvm-bolt \
		"$orig" \
		-o "$f" \
		--data "$f".prof.fdata \
		"${BOLT_FULL_FLAGS[@]}" 2>&1)"; then
		touch "$f".bolt-converted
		printf 'XXX I BOLT: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-out
	else
		printf 'XXX E BOLT: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-err
		printf 'XXX E BOLT: %s\n' "$f" >&2
		cp -a "$orig" "$f"
		return 1
	fi
}
export -f bolt_with_profile
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
		parallel -0 --line-buffer -j "$BOLT_JOBS" bolt_with_profile {}
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
printf -- '\t%s\tRun-instrumented\n' '---'
printf -- '\t%s\tRun-optimized\n' "$([ "$rc_optim" -eq 0 ] && echo PASS || echo FAIL)"
printf -- '\n'
printf -- '\n'
printf -- 'Notable entries in e.log\n'
printf -- '------------------------\n'
printf -- '\n'
if [ -s e.log ]; then
	grep -E '^XXX (W|E) (harness|BOLT|INSTRUMENT):' e.log |
		while IFS= read -r line; do
			printf '\t%s\n' "$line"
		done
fi
printf -- '\n'
printf -- '---\n'

exit "$((rc_optim))"
