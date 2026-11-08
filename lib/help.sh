# shellcheck shell=bash
# lib/help.sh -- hub: sourcea los 4 modulos de ayuda.
# El orden importa: help_index define los helpers (_help_title, _help_cat,
# etc.) que los otros 3 usan.
_hdir="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "${_hdir}/help_index.sh"
# shellcheck source=/dev/null
source "${_hdir}/help_wifi.sh"
# shellcheck source=/dev/null
source "${_hdir}/help_networks.sh"
# shellcheck source=/dev/null
source "${_hdir}/help_system.sh"
unset _hdir
