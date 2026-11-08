# shellcheck shell=bash
# lib/radio.sh -- hub: state + roles + ops.
# Orden: state define RADIO_* y helpers de kernel; roles y ops los usan.
_rdir="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "${_rdir}/radio_state.sh"
# shellcheck source=/dev/null
source "${_rdir}/radio_roles.sh"
# shellcheck source=/dev/null
source "${_rdir}/radio_ops.sh"
unset _rdir
