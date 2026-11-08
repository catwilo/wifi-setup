#!/usr/bin/env bats
# regression.bats -- invariantes de los fixes del bug reportado.
#
# Cubre el comportamiento observable de cada fix sin depender de NM vivo:
#   - nm_device_connect usa "nmcli device connect" (nunca "nmcli con up")
#   - nm_con_up lleva --wait 90 (tope, no bloqueo indefinido)
#   - _cmd_connect, radio_up y radio_boot usan nm_device_connect
#   - fallback_off devuelve non-zero sin IP y preserva fallback_state
#   - DNS: systemd-resolved habilitado + symlink stub-resolv.conf + iwd
#     delega con NameResolvingService=systemd

load helpers

setup() { setup_env; }

@test "nm_device_connect: usa nmcli device connect, no con up" {
    run grep -A5 '^nm_device_connect()' "$REPO/lib/nm.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'nmcli device connect'* ]]
    [[ "$output" != *'nmcli con up'* ]]
}

@test "nm_con_up: lleva --wait 90 (tope, no bloqueo indefinido)" {
    run grep -A5 '^nm_con_up()' "$REPO/lib/nm.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'--wait 90'* ]]
}

@test "_cmd_connect: usa nm_device_connect, no nm_con_up" {
    run grep -A40 '^_cmd_connect()' "$REPO/lib/cli_commands.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'nm_device_connect'* ]]
    [[ "$output" != *'nm_con_up'* ]]
}

@test "radio_up: usa nm_device_connect, no nm_con_up" {
    run grep -A40 '^radio_up()' "$REPO/lib/radio_ops.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'nm_device_connect'* ]]
    [[ "$output" != *'nm_con_up'* ]]
}

@test "radio_boot: usa nm_device_connect, no nm_con_up" {
    run grep -A80 '^radio_boot()' "$REPO/lib/radio_ops.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'nm_device_connect'* ]]
    [[ "$output" != *'nm_con_up'* ]]
}

@test "fallback_off: non-zero sin IP y preserva fallback_state" {
    run grep -A120 '^fallback_off()' "$REPO/lib/fallback_ops.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'ninguna antena obtuvo IP'* ]]
    [[ "$output" == *'fallback_state preservado'* ]]
    [[ "$output" == *'return 1'* ]]
}

@test "DNS: _deps_ensure_resolved habilita systemd-resolved y symlinkea stub-resolv.conf" {
    run grep -A25 '^_deps_ensure_resolved()' "$REPO/lib/deps.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'systemd-resolved'* ]]
    [[ "$output" == *'stub-resolv.conf'* ]]
    [[ "$output" == *'ln -sfn'* ]]
}

@test "DNS: fallback.sh delega a systemd (NameResolvingService=systemd, no none)" {
    run grep 'NameResolvingService' "$REPO/lib/fallback_state.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'systemd'* ]]
    [[ "$output" != *'NameResolvingService=none'* ]]
}

# ---------------------------------------------------------------------------
# Proteccion contra el bug del 2026-11-06:
#
# _fallback_ensure_iwd_netconf DEBE escribir [DriverQuirks]
# DefaultInterface=?* en /etc/iwd/main.conf. Sin esa directiva,
# 'systemctl stop iwd' destruye wlan0 del kernel (driver brcmsmac), NM
# arranca sin ver la iface, timeout, nodo sin red. Es el fix que mas
# duele perder: elimina la interfaz fisica.
#
# DEBE ademas no duplicar [General]: iwd lee solo la primera ocurrencia,
# asi que una duplicacion silenciosa desactiva EnableNetworkConfiguration
# y iwd deja de hacer DHCP.
#
# Los tests extraen el Python del heredoc y lo ejecutan contra inputs
# sinteticos, verificando comportamiento real (no un grep del codigo).
# ---------------------------------------------------------------------------

_extract_netconf_python() {
    local out="$1"
    awk '
        /<<.PY_IWD_CONF.$/ { p=1; next }
        /^PY_IWD_CONF$/ { exit }
        p { print }
    ' "$REPO/lib/fallback_state.sh" > "$out"
    [ -s "$out" ]
}

@test "_fallback_ensure_iwd_netconf: escribe [DriverQuirks] DefaultInterface=?*" {
    local py="$BATS_TEST_TMPDIR/netconf.py"
    _extract_netconf_python "$py" || { echo "no se pudo extraer el Python"; return 1; }
    local src="$BATS_TEST_TMPDIR/main.conf.in"
    local dst="$BATS_TEST_TMPDIR/main.conf.out"
    : > "$src"
    python3 "$py" "$src" "$dst"
    grep -qxF '[DriverQuirks]' "$dst" || { echo "falta [DriverQuirks]"; cat "$dst"; return 1; }
    grep -qxF 'DefaultInterface=?*' "$dst" || { echo "falta DefaultInterface=?*"; cat "$dst"; return 1; }
}

@test "_fallback_ensure_iwd_netconf: no duplica [General]/[Network]/[DriverQuirks]" {
    local py="$BATS_TEST_TMPDIR/netconf.py"
    _extract_netconf_python "$py" || { echo "no se pudo extraer el Python"; return 1; }
    local src="$BATS_TEST_TMPDIR/main.conf.in"
    local dst="$BATS_TEST_TMPDIR/main.conf.out"
    cat > "$src" <<'EOF'
[General]
# stale comment
[Network]
# stale comment
[General]
EnableNetworkConfiguration=true
EOF
    python3 "$py" "$src" "$dst"
    [ "$(grep -c '^\[General\]$' "$dst")" -eq 1 ] || { echo "General duplicado"; cat "$dst"; return 1; }
    [ "$(grep -c '^\[Network\]$' "$dst")" -eq 1 ] || { echo "Network duplicado"; cat "$dst"; return 1; }
    [ "$(grep -c '^\[DriverQuirks\]$' "$dst")" -eq 1 ] || { echo "DriverQuirks duplicado"; cat "$dst"; return 1; }
    grep -qxF 'EnableNetworkConfiguration=true' "$dst"
    grep -qxF 'NameResolvingService=systemd' "$dst"
    grep -qxF 'DefaultInterface=?*' "$dst"
}

@test "fallback_on: llama _fallback_fix_routes tras esperar IP (bug brcmsmac)" {
    run grep -A120 '^fallback_on\(\)' "$REPO/lib/fallback_ops.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'_fallback_fix_routes'* ]]
}
