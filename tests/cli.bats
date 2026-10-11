#!/usr/bin/env bats
# cli.bats -- comportamiento observable del CLI:
# guarda Debian, --help, dispatch.

load helpers

setup() { setup_env; }

# --- guarda Debian: en plataforma no-Debian (PREFIX/bin) sale limpio ---

@test "install.sh: no-Debian -> exit 0 sin efectos" {
    mkdir -p "$BATS_TEST_TMPDIR/fake-prefix/bin"
    run env PREFIX="$BATS_TEST_TMPDIR/fake-prefix" bash "$INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no-Debian"* ]]
}

@test "uninstall.sh: no-Debian -> exit 0 sin efectos" {
    mkdir -p "$BATS_TEST_TMPDIR/fake-prefix/bin"
    run env PREFIX="$BATS_TEST_TMPDIR/fake-prefix" bash "$UNINSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no-Debian"* ]]
}

@test "checks.sh: no-Debian -> exit 0 sin efectos" {
    mkdir -p "$BATS_TEST_TMPDIR/fake-prefix/bin"
    run env PREFIX="$BATS_TEST_TMPDIR/fake-prefix" bash "$CHECKS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no-Debian"* ]]
}

# --- --help de cada entrypoint ---

@test "install.sh --help: exit 0 con texto de uso" {
    run bash "$INSTALL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"uso: sudo wifi install"* ]]
}

@test "uninstall.sh --help: exit 0 con texto de uso" {
    run bash "$UNINSTALL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"uso: sudo wifi uninstall"* ]]
}

@test "checks.sh --help: exit 0 con texto de uso" {
    run bash "$CHECKS" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"uso: sudo wifi check"* ]]
}

@test "bin/wifi --help: exit 0 con la ayuda completa" {
    run bash "$WIFI" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"wifi-setup"* ]]
    [[ "$output" == *"radio"* ]]
    [[ "$output" == *"lan"* ]]
    [[ "$output" == *"usb-names"* ]]
    [[ "$output" == *"vpn"* ]]
}

@test "bin/wifi sin args: exit 0 con la ayuda" {
    run bash "$WIFI"
    [ "$status" -eq 0 ]
    [[ "$output" == *"wifi-setup"* ]]
}

@test "bin/wifi comando desconocido: exit != 0 con hint" {
    run bash "$WIFI" bogus-cmd
    [ "$status" -ne 0 ]
    [[ "$output" == *"comando desconocido"* ]]
    [[ "$output" == *"wifi help"* ]]
}

# --- dispatch: cada subcomando del case tiene su _cmd_* definido ---

@test "bin/wifi: todos los subcomandos del dispatch tienen funcion _cmd_*" {
    cd "$REPO"
    local subs fn sub
    subs="$(sed -n '/^case "\${CMD}"/,/^esac/p' bin/wifi \
        | grep -oE '^\s+[a-z-]+\)' | tr -d ' )' | sort -u || true)"
    [ -n "$subs" ]
    while IFS= read -r sub; do
        case "$sub" in
            install|uninstall|remove|check|verify|version|help) continue ;;
            -*) continue ;;
        esac
        fn="_cmd_$(printf '%s' "$sub" | tr '-' '_')"
        if ! grep -qE "^${fn}\(\)" bin/wifi; then
            echo "subcomando '${sub}' sin funcion ${fn}()" >&3
            return 1
        fi
    done <<< "$subs"
}
