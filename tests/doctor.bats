#!/usr/bin/env bats
# doctor.bats -- comportamiento de las funciones de reporte de doctor.sh.
# Invocan con estado controlado y verifican el resultado, no el texto.

load helpers

setup() {
    setup_env

    # Stubs minimos que doctor.sh espera de common.sh
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

# --- contadores basicos ---

@test "_doctor_ok incrementa DOCTOR_OK" {
    doctor_reset
    _doctor_ok "test" 2>/dev/null
    [ "$DOCTOR_OK" -eq 1 ]
    [ "$DOCTOR_WARN" -eq 0 ]
    [ "$DOCTOR_FAIL" -eq 0 ]
}

@test "_doctor_warn incrementa DOCTOR_WARN" {
    doctor_reset
    _doctor_warn "test" 2>/dev/null
    [ "$DOCTOR_WARN" -eq 1 ]
    [ "$DOCTOR_OK" -eq 0 ]
}

@test "_doctor_fail incrementa DOCTOR_FAIL" {
    doctor_reset
    _doctor_fail "test" 2>/dev/null
    [ "$DOCTOR_FAIL" -eq 1 ]
}

@test "_doctor_fix incrementa DOCTOR_FIX" {
    doctor_reset
    _doctor_fix "test" 2>/dev/null
    [ "$DOCTOR_FIX" -eq 1 ]
}

# --- summary: exit code segun FAIL ---

@test "_doctor_summary: return 0 si no hay FAIL" {
    doctor_reset
    DOCTOR_OK=3
    DOCTOR_WARN=2
    run _doctor_summary
    [ "$status" -eq 0 ]
}

@test "_doctor_summary: return 1 si hay al menos un FAIL" {
    doctor_reset
    DOCTOR_OK=3
    DOCTOR_FAIL=1
    run _doctor_summary
    [ "$status" -eq 1 ]
}

@test "_doctor_summary: imprime conteos OK/WARN/FAIL" {
    doctor_reset
    DOCTOR_OK=5
    DOCTOR_WARN=2
    DOCTOR_FAIL=1
    run _doctor_summary
    [[ "$output" == *"5 OK"* ]]
    [[ "$output" == *"2 WARN"* ]]
    [[ "$output" == *"1 FAIL"* ]]
}

@test "_doctor_summary: muestra FIX solo si hay fixes" {
    doctor_reset
    DOCTOR_OK=1
    run _doctor_summary
    [[ "$output" != *"FIX"* ]]

    doctor_reset
    DOCTOR_OK=1
    DOCTOR_FIX=2
    run _doctor_summary
    [[ "$output" == *"2 FIX"* ]]
}

# --- doctor_reset ---

@test "doctor_reset: limpia todos los contadores" {
    DOCTOR_OK=10
    DOCTOR_WARN=5
    DOCTOR_FAIL=3
    DOCTOR_FIX=2
    doctor_reset
    [ "$DOCTOR_OK" -eq 0 ]
    [ "$DOCTOR_WARN" -eq 0 ]
    [ "$DOCTOR_FAIL" -eq 0 ]
    [ "$DOCTOR_FIX" -eq 0 ]
}

# --- doctor_run: modo y modo --fix ---

@test "doctor_run: sin args -> DOCTOR_FIX_MODE=0" {
    # Stub de los chequeos para no tocar el sistema
    _doctor_check_services() { :; }
    _doctor_check_radios() { :; }
    _doctor_check_profiles() { :; }
    _doctor_check_usb_links() { :; }
    _doctor_check_symlink() { :; }
    _doctor_check_tailscale() { :; }

    doctor_run 2>/dev/null
    [ "$DOCTOR_FIX_MODE" -eq 0 ]
}

@test "doctor_run --fix -> DOCTOR_FIX_MODE=1" {
    _doctor_check_services() { :; }
    _doctor_check_radios() { :; }
    _doctor_check_profiles() { :; }
    _doctor_check_usb_links() { :; }
    _doctor_check_symlink() { :; }
    _doctor_check_tailscale() { :; }

    doctor_run --fix 2>/dev/null
    [ "$DOCTOR_FIX_MODE" -eq 1 ]
}
