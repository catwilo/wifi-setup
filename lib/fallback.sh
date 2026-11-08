# shellcheck shell=bash
# lib/fallback.sh -- hub: sourcea state + ops.
# state define los helpers que ops usa; el orden importa.
_fdir="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "${_fdir}/fallback_state.sh"
# shellcheck source=/dev/null
source "${_fdir}/fallback_ops.sh"
unset _fdir
