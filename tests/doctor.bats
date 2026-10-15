#!/usr/bin/env bats
# doctor.bats -- contrato de los contadores y el summary de doctor.sh.

load helpers

setup() {
    setup_env
    C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''
    info()  { :; }
    warn()  { :; }
    ok()    { :; }
    die()   { echo "die: $*" >&2; return 1; }
    require_dirs() { :; }
    export -f info warn ok die require_dirs 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$REPO/lib/doctor.sh"
}

@test "_doctor_{ok,warn,fail,fix}: cada uno incrementa solo su contador" {
    doctor_reset; _doctor_ok   "x" 2>/dev/null; [ "$DOCTOR_OK"   -eq 1 ]
    doctor_reset; _doctor_warn "x" 2>/dev/null; [ "$DOCTOR_WARN" -eq 1 ]
    doctor_reset; _doctor_fail "x" 2>/dev/null; [ "$DOCTOR_FAIL" -eq 1 ]
    doctor_reset; _doctor_fix  "x" 2>/dev/null; [ "$DOCTOR_FIX"  -eq 1 ]
}

@test "doctor_reset: limpia todos los contadores" {
    DOCTOR_OK=10 DOCTOR_WARN=5 DOCTOR_FAIL=3 DOCTOR_FIX=2
    doctor_reset
    [ "$DOCTOR_OK" -eq 0 ] && [ "$DOCTOR_WARN" -eq 0 ]
    [ "$DOCTOR_FAIL" -eq 0 ] && [ "$DOCTOR_FIX" -eq 0 ]
}

@test "_doctor_summary: exit 0 sin FAIL, exit 1 con FAIL, e imprime conteos" {
    doctor_reset; DOCTOR_OK=3 DOCTOR_WARN=2
    run _doctor_summary
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 OK"* ]] && [[ "$output" == *"2 WARN"* ]]

    doctor_reset; DOCTOR_OK=5 DOCTOR_WARN=2 DOCTOR_FAIL=1
    run _doctor_summary
    [ "$status" -eq 1 ]
    [[ "$output" == *"5 OK"* ]] && [[ "$output" == *"1 FAIL"* ]]
}

@test "doctor_run: --fix activa DOCTOR_FIX_MODE, sin args lo deja en 0" {
    _doctor_check_services() { :; }; _doctor_check_radios()   { :; }
    _doctor_check_profiles() { :; }; _doctor_check_usb_links() { :; }
    _doctor_check_symlink()  { :; }; _doctor_check_tailscale() { :; }

    doctor_run 2>/dev/null
    [ "$DOCTOR_FIX_MODE" -eq 0 ]
    doctor_run --fix 2>/dev/null
    [ "$DOCTOR_FIX_MODE" -eq 1 ]
}

@test "_doctor_try_fix_orphan: no toca nmcli sin DOCTOR_FIX_MODE ni config" {
    DOCTOR_FIX_MODE=0
    nmcli() { echo "NMCLI llamado sin permiso" >&2; return 1; }
    export -f nmcli 2>/dev/null || true
    _doctor_try_fix_orphan "wifi-viejo-ssid" "vieja0" 2>/dev/null || true

    DOCTOR_FIX_MODE=1
    CONFIG_DIR="$BATS_TEST_TMPDIR/no-config"
    LIB_DIR="$BATS_TEST_TMPDIR/no-lib"
    mkdir -p "$CONFIG_DIR" "$LIB_DIR"
    local called=0
    nmcli() { called=1; return 1; }
    export -f nmcli 2>/dev/null || true
    _doctor_try_fix_orphan "perfil-x" "vieja0" 2>/dev/null || true
    [ "$called" -eq 0 ]
}
