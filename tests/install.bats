#!/usr/bin/env bats
# install.bats -- invariantes de estructura en install.sh.
# Detectan regresiones de bugs ya arreglados: variables usadas antes de
# definirse, orden de bloques, ausencia de residuos del diseno viejo.

load helpers

setup() { setup_env; }

# --- variables definidas antes de usarse ---

@test "install.sh: WIFI_BIN y WIFI_REPO_BIN se declaran antes del pre-check de idempotencia" {
    # El pre-check usa ${WIFI_BIN} y ${WIFI_REPO_BIN}. Deben estar
    # declaradas ANTES de cualquier uso. Regresion del bug "WIFI_BIN:
    # unbound variable" con set -u.
    local ln_decl ln_use
    ln_decl="$(grep -n '^    local WIFI_BIN=' "$INSTALL" | head -1 | cut -d: -f1)"
    ln_use="$(grep -n '_idem_symlink' "$INSTALL" | head -1 | cut -d: -f1)"
    [ -n "$ln_decl" ] && [ -n "$ln_use" ]
    [ "$ln_decl" -lt "$ln_use" ]
}

@test "install.sh: LOG_DIR_USER se declara antes de _relaunch_in_tmux" {
    local ln_decl ln_fn
    ln_decl="$(grep -n '^LOG_DIR_USER=' "$INSTALL" | head -1 | cut -d: -f1)"
    ln_fn="$(grep -n '^_relaunch_in_tmux()' "$INSTALL" | head -1 | cut -d: -f1)"
    [ -n "$ln_decl" ] && [ -n "$ln_fn" ]
    [ "$ln_decl" -lt "$ln_fn" ]
}

@test "install.sh: _root_phase() se define antes del handler que la invoca" {
    local ln_fn ln_handler
    ln_fn="$(grep -n '^_root_phase()' "$INSTALL" | head -1 | cut -d: -f1)"
    ln_handler="$(grep -n 'if \[\[ "${1:-}" == "--root-phase"' "$INSTALL" | head -1 | cut -d: -f1)"
    [ -n "$ln_fn" ] && [ -n "$ln_handler" ]
    [ "$ln_fn" -lt "$ln_handler" ]
}

@test "install.sh: _relaunch_in_tmux() se define antes de su llamada" {
    local ln_fn ln_call
    ln_fn="$(grep -n '^_relaunch_in_tmux()' "$INSTALL" | head -1 | cut -d: -f1)"
    ln_call="$(grep -n '^_relaunch_in_tmux "\$@"' "$INSTALL" | head -1 | cut -d: -f1)"
    [ -n "$ln_fn" ] && [ -n "$ln_call" ]
    [ "$ln_fn" -lt "$ln_call" ]
}

# --- anti-loop del relaunch: usa WIFI_SETUP_INWIN, no TMUX ---

@test "install.sh: relaunch se protege con WIFI_SETUP_INWIN, no con TMUX" {
    # Si usara ${TMUX} como flag, correr el script dentro de tmux (como
    # hace el usuario) no abriria ventana nueva. El flag debe ser propio.
    run grep -q 'WIFI_SETUP_INWIN' "$INSTALL"
    [ "$status" -eq 0 ]
}

@test "install.sh: relaunch crea ventana en la sesion actual si hay TMUX" {
    # Usa 'tmux display-message -p #S' para obtener la sesion actual.
    run grep -q "tmux display-message -p '#S'" "$INSTALL"
    [ "$status" -eq 0 ]
}

# --- idempotencia ---

@test "install.sh: pre-check de idempotencia existe" {
    run grep -q 'wifi-setup ya instalado' "$INSTALL"
    [ "$status" -eq 0 ]
}

# --- seguridad ---

@test "install.sh: rechaza correr como root directo" {
    run grep -q 'install.sh debe correr como usuario' "$INSTALL"
    [ "$status" -eq 0 ]
}

@test "install.sh: PSK se pide dentro de _root_phase" {
    local ln_fn ln_psk
    ln_fn="$(grep -n '^_root_phase()' "$INSTALL" | head -1 | cut -d: -f1)"
    ln_psk="$(grep -n 'read -r -s -p "PSK' "$INSTALL" | head -1 | cut -d: -f1)"
    [ -n "$ln_fn" ] && [ -n "$ln_psk" ]
    [ "$ln_psk" -gt "$ln_fn" ]
}

# --- verificacion final ---

@test "install.sh: verificacion final imprime PASS y FAIL" {
    run grep -q '\[PASS\]' "$INSTALL"; [ "$status" -eq 0 ]
    run grep -q '\[FAIL\]' "$INSTALL"; [ "$status" -eq 0 ]
}

@test "install.sh: ventana tmux espera ENTER antes de cerrar" {
    run grep -q 'ENTER para cerrar esta ventana' "$INSTALL"
    [ "$status" -eq 0 ]
}

@test "install.sh: ventana imprime RESULTADO OK o FALLO al terminar" {
    run grep -q 'RESULTADO: OK' "$INSTALL"; [ "$status" -eq 0 ]
    run grep -q 'RESULTADO: FALLO' "$INSTALL"; [ "$status" -eq 0 ]
}

# --- ausencia de residuos del diseno viejo ---

@test "install.sh: sin safe_run ni canary ni /opt/wifi-setup" {
    run grep -q 'safe_run' "$INSTALL";        [ "$status" -ne 0 ]
    run grep -q 'canary' "$INSTALL";          [ "$status" -ne 0 ]
    run grep -q '/opt/wifi-setup' "$INSTALL"; [ "$status" -ne 0 ]
}

@test "lib/safe.sh: eliminado" {
    [ ! -e "$REPO/lib/safe.sh" ]
}

@test "bin/wifi: sin _cmd_canary ni _cmd_safe" {
    run grep -q '_cmd_canary' "$WIFI"; [ "$status" -ne 0 ]
    run grep -q '_cmd_safe' "$WIFI";   [ "$status" -ne 0 ]
}

@test "lib/: sin net.sh, forward.sh, uplink.sh, survival.sh, tailscale.sh" {
    local f
    for f in net.sh forward.sh uplink.sh survival.sh tailscale.sh; do
        [ ! -e "$REPO/lib/$f" ] || {
            echo "residuo del diseno viejo: lib/$f" >&3
            return 1
        }
    done
}
