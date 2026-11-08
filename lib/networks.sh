# shellcheck shell=bash
# lib/networks.sh -- hub: store + pull + apply + show.
# Orden: store define NETWORKS_STORE y primitivos; pull y apply los usan; show solo lee.
_ndir="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "${_ndir}/networks_store.sh"
# shellcheck source=/dev/null
source "${_ndir}/networks_pull.sh"
# shellcheck source=/dev/null
source "${_ndir}/networks_apply.sh"
# shellcheck source=/dev/null
source "${_ndir}/networks_show.sh"
unset _ndir
