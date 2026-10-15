#!/usr/bin/env bats
# cli.bats -- contrato observable del CLI: guarda Debian, --help, dispatch.

load helpers

setup() { setup_env; }

@test "entrypoints no-Debian: exit 0 sin efectos" {
    local f
    mkdir -p "$BATS_TEST_TMPDIR/fake-prefix/bin"
    for f in "$INSTALL" "$UNINSTALL" "$CHECKS"; do
        run env PREFIX="$BATS_TEST_TMPDIR/fake-prefix" bash "$f"
        [ "$status" -eq 0 ] || { echo "$f: status=$status" >&3; return 1; }
        [[ "$output" == *"no-Debian"* ]] || { echo "$f: sin 'no-Debian'" >&3; return 1; }
    done
}

@test "entrypoints --help: exit 0 con texto de uso" {
    run bash "$INSTALL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"uso: sudo wifi install"* ]]

    run bash "$UNINSTALL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"uso: sudo wifi uninstall"* ]]

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
    [[ "$output" == *"fallback"* ]]
}

@test "bin/wifi comando desconocido: exit != 0 con hint" {
    run bash "$WIFI" bogus-cmd
    [ "$status" -ne 0 ]
    [[ "$output" == *"comando desconocido"* ]]
    [[ "$output" == *"wifi help"* ]]
}

@test "bin/wifi: subcomandos del dispatch tienen funcion _cmd_*" {
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
