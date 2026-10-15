#!/usr/bin/env bats
# install.bats -- invariantes de install.sh que atrapan regresiones reales.

load helpers

setup() { setup_env; }

@test "install.sh: WIFI_BIN se declara antes del pre-check de idempotencia" {
    local ln_decl ln_use
    ln_decl="$(grep -n '^    local WIFI_BIN=' "$INSTALL" | head -1 | cut -d: -f1)"
    ln_use="$(grep -n '_idem_symlink' "$INSTALL" | head -1 | cut -d: -f1)"
    [ -n "$ln_decl" ] && [ -n "$ln_use" ] && [ "$ln_decl" -lt "$ln_use" ]
}

@test "install.sh: LOG_DIR_USER se declara antes de _relaunch_in_tmux" {
    local ln_decl ln_fn
    ln_decl="$(grep -n '^LOG_DIR_USER=' "$INSTALL" | head -1 | cut -d: -f1)"
    ln_fn="$(grep -n '^_relaunch_in_tmux()' "$INSTALL" | head -1 | cut -d: -f1)"
    [ -n "$ln_decl" ] && [ -n "$ln_fn" ] && [ "$ln_decl" -lt "$ln_fn" ]
}

@test "install.sh: _root_phase se define antes del handler --root-phase" {
    local ln_fn ln_handler
    ln_fn="$(grep -n '^_root_phase()' "$INSTALL" | head -1 | cut -d: -f1)"
    ln_handler="$(grep -n 'if \[\[ "${1:-}" == "--root-phase"' "$INSTALL" | head -1 | cut -d: -f1)"
    [ -n "$ln_fn" ] && [ -n "$ln_handler" ] && [ "$ln_fn" -lt "$ln_handler" ]
}

@test "install.sh: _relaunch_in_tmux se define antes de su llamada" {
    local ln_fn ln_call
    ln_fn="$(grep -n '^_relaunch_in_tmux()' "$INSTALL" | head -1 | cut -d: -f1)"
    ln_call="$(grep -n '^_relaunch_in_tmux "\$@"' "$INSTALL" | head -1 | cut -d: -f1)"
    [ -n "$ln_fn" ] && [ -n "$ln_call" ] && [ "$ln_fn" -lt "$ln_call" ]
}

@test "install.sh: relaunch se protege con WIFI_SETUP_INWIN (anti-loop)" {
    run grep -q 'WIFI_SETUP_INWIN' "$INSTALL"; [ "$status" -eq 0 ]
}

@test "install.sh: rechaza correr como root directo" {
    run grep -q 'install.sh debe correr como usuario' "$INSTALL"; [ "$status" -eq 0 ]
}

@test "install.sh: PSK se pide dentro de _root_phase (no via argv)" {
    local ln_fn ln_psk
    ln_fn="$(grep -n '^_root_phase()' "$INSTALL" | head -1 | cut -d: -f1)"
    ln_psk="$(grep -n 'read -r -s -p "PSK' "$INSTALL" | head -1 | cut -d: -f1)"
    [ -n "$ln_fn" ] && [ -n "$ln_psk" ] && [ "$ln_psk" -gt "$ln_fn" ]
}

@test "install.sh: pre-check de idempotencia existe" {
    run grep -q 'wifi-setup ya instalado' "$INSTALL"; [ "$status" -eq 0 ]
}

@test "install.sh: LOG_FILE se declara en _root_phase (WIFI_SETUP_LOG propagado)" {
    local ln_fn ln_log
    ln_fn="$(grep -n '^_root_phase()' "$INSTALL" | head -1 | cut -d: -f1)"
    ln_log="$(grep -n 'LOG_FILE="\${WIFI_SETUP_LOG' "$INSTALL" | head -1 | cut -d: -f1)"
    [ -n "$ln_fn" ] && [ -n "$ln_log" ] && [ "$ln_log" -gt "$ln_fn" ]
}

@test "install.sh: checks de is-enabled no usan pipe con grep (rompe con pipefail)" {
    ! grep -qE 'is-enabled [a-z]+ 2>/dev/null \| grep' "$INSTALL"
    grep -qE 'is-enabled [a-z]+ 2>/dev/null \|\| true' "$INSTALL"
}

@test "repo: sin residuos del diseno viejo" {
    run grep -q 'safe_run' "$INSTALL";        [ "$status" -ne 0 ]
    run grep -q 'canary' "$INSTALL";          [ "$status" -ne 0 ]
    run grep -q '/opt/wifi-setup' "$INSTALL"; [ "$status" -ne 0 ]
    run grep -q '_cmd_canary' "$WIFI";        [ "$status" -ne 0 ]
    run grep -q '_cmd_safe'   "$WIFI";        [ "$status" -ne 0 ]
    [ ! -e "$REPO/lib/safe.sh" ]
    local f
    for f in net.sh forward.sh uplink.sh survival.sh tailscale.sh; do
        [ ! -e "$REPO/lib/$f" ] || { echo "residuo: lib/$f" >&3; return 1; }
    done
}
