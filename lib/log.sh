#!/usr/bin/env bash
# lib/log.sh — logging modular: prefijos [OK]/[WARN]/[ERR]/[..]/[i] + color,
# secciones jerárquicas, spinner TTY-aware. Escribe a archivo sin ANSI.
# Sustituye a log(). Niveles: ok|warn|err|info|step.

LOG_DIR="${LOG_DIR:-/opt/wifi-setup/logs}"
_LOG_FILE="${LOG_DIR}/wifi-setup.log"

if [[ -t 1 ]]; then
    _C_RST=$'\033[0m'; _C_G=$'\033[32m'; _C_Y=$'\033[33m'
    _C_R=$'\033[31m'; _C_C=$'\033[36m'; _C_DIM=$'\033[2m'; _C_B=$'\033[1m'
    _TTY=1
else
    _C_RST=; _C_G=; _C_Y=; _C_R=; _C_C=; _C_DIM=; _C_B=; _TTY=0
fi

_log_file() {
    # Escribe línea sin ANSI al archivo (best-effort, sin romper si no hay permiso)
    if mkdir -p "${LOG_DIR}" 2>/dev/null && [[ -w "${LOG_DIR}" ]]; then
        printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "${_LOG_FILE}" 2>/dev/null || true
    fi
}

# section "Título" — encabezado de bloque
section() {
    printf '\n%s%s▸ %s%s\n' "${_C_B}" "${_C_C}" "$*" "${_C_RST}" >&2
    _log_file "== $* =="
}

# Niveles. Pasos indentados bajo la sección.
ok()   { printf '  %s[OK]%s %s\n'   "${_C_G}" "${_C_RST}" "$*" >&2; _log_file "[OK] $*"; }
warn() { printf '  %s[WARN]%s %s\n' "${_C_Y}" "${_C_RST}" "$*" >&2; _log_file "[WARN] $*"; }
err()  { printf '  %s[ERR]%s %s\n'  "${_C_R}" "${_C_RST}" "$*" >&2; _log_file "[ERR] $*"; }
info() { printf '  %s[i]%s %s\n'    "${_C_C}" "${_C_RST}" "$*" >&2; _log_file "[i] $*"; }

# step "msg" cmd args... — corre cmd con spinner (TTY) o [..]->[OK] (no TTY).
# Devuelve el código de salida del cmd.
step() {
    local msg="$1"; shift
    _log_file "[..] ${msg}"
    if [[ "${_TTY}" -eq 1 ]]; then
        local sp='|/-\' i=0
        ( "$@" ) & local pid=$!
        printf '  %s[..]%s %s ' "${_C_DIM}" "${_C_RST}" "${msg}" >&2
        while kill -0 "${pid}" 2>/dev/null; do
            printf '\b%s' "${sp:i++%4:1}" >&2; sleep 0.1
        done
        wait "${pid}"; local rc=$?
        printf '\b' >&2
        if [[ ${rc} -eq 0 ]]; then printf '\r  %s[OK]%s %s   \n' "${_C_G}" "${_C_RST}" "${msg}" >&2; _log_file "[OK] ${msg}"
        else printf '\r  %s[ERR]%s %s   \n' "${_C_R}" "${_C_RST}" "${msg}" >&2; _log_file "[ERR] ${msg}"; fi
        return ${rc}
    else
        printf '  [..] %s\n' "${msg}" >&2
        "$@"; local rc=$?
        if [[ ${rc} -eq 0 ]]; then ok "${msg}"; else err "${msg}"; fi
        return ${rc}
    fi
}
