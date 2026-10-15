#!/usr/bin/env bats
# syntax.bats -- bash -n + shellcheck sobre todo el codigo shell del repo.

load helpers

setup() { setup_env; }

@test "entrypoints: bash -n OK" {
    local f
    for f in "$INSTALL" "$UNINSTALL" "$CHECKS" "$WIFI"; do
        run bash -n "$f"
        [ "$status" -eq 0 ] || { echo "syntax error en $f:" >&3; echo "$output" >&3; return 1; }
    done
}

@test "lib/*.sh: bash -n OK" {
    local f
    for f in "$REPO"/lib/*.sh; do
        run bash -n "$f"
        [ "$status" -eq 0 ] || { echo "syntax error en $f:" >&3; echo "$output" >&3; return 1; }
    done
}

@test "shellcheck limpio (usa .shellcheckrc)" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck no instalado"
    cd "$REPO"
    run shellcheck -x install.sh uninstall.sh checks.sh bin/wifi lib/*.sh
    [ "$status" -eq 0 ] || { echo "$output" >&3; return 1; }
}
