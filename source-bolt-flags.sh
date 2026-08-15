#!/bin/bash
# shellcheck disable=SC2034
# vim: set tabstop=8 shiftwidth=8 softtabstop=8 noexpandtab:
# SPDX-License-Identifier: GPL-3.0-or-later

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	printf 'Error: %s must be sourced, not executed.\n' "${BASH_SOURCE[0]}" >&2
	exit 2
fi

BOLT_SMOKE_FLAGS=(
	'-reorder-functions=hfsort'
	'-split-functions'
	'-split-all-cold'
)

BOLT_INSTRUMENT_FLAGS=(
	'--instrument'
	'--instrument-load-profiles'
	'--instrumentation-file-append-pid'
)

BOLT_FULL_FLAGS=(
	'--reorder-functions=cdsort'
	'--reorder-blocks=ext-tsp'
	'--split-strategy=profile2'
	'--split-functions'
	'--align-hot-loop-headers'
	'--hot-loop-alignment=32'
	'--hot-loop-alignment-max-bytes=32'
	'--icp=all'
	'--icp-jump-tables-targets'
	'--simplify-rodata-loads'
	'--frame-opt=all'
	'--frame-opt-rm-stores'
	'--experimental-shrink-wrapping'
	'--peepholes=all'
	'--hugify'
	"--huge-page-size=$(numfmt --from=auto '32Mi')"
	"--align-text=$(numfmt --from=auto '2Mi')"
	'--icf=safe'
	'--dyno-stats'
)
