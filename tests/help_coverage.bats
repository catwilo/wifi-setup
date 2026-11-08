#!/usr/bin/env bats
# help_coverage.bats -- cada comando del dispatch tiene help_<cmd>, y el
# help_index no menciona comandos que no existen en el dispatch.
#
# Regresion cubierta:
#   - 226169: help mencionaba comandos podados (doctor/lan/vpn/monitor/panic).
#   - refactor 2026-11-07: movio _cmd_* a cli_commands.sh y partio help.sh
#     en 4 modulos. Sin este test, un comando nuevo sin help_<cmd> pasaria
#     desapercibido; o al reves, help huerfano tras podar un comando.

load helpers

setup() {
    setup_env
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/help.sh"
}

# Lista los comandos del dispatch, excluyendo:
#   - "" (artefacto del case `help|-h|--help|"")`)
#   - help (meta-comando: _cmd_help invoca help_index directo, no _maybe_help;
#     `wifi help -h` ya imprime el indice completo, help_help seria circular)
_dispatch_cmds() {
    sed -n '/^case "${CMD}" in/,/^esac/p' "$WIFI" \
        | grep -E '^    [a-z|-]' \
        | sed 's/^    //; s/).*//' \
        | tr '|' '\n' \
        | grep -vE '^-|^$|^""$' \
        | grep -vx 'help' \
        | sort -u
}

@test "help_coverage: dispatch tiene al menos un comando" {
    run _dispatch_cmds
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "help_coverage: cada comando del dispatch tiene help_<cmd>" {
    local missing=()
    local cmd fn
    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        fn="help_${cmd//-/_}"
        if ! declare -F "$fn" >/dev/null 2>&1; then
            missing+=("$cmd ($fn)")
        fi
    done < <(_dispatch_cmds)

    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'sin help: %s\n' "${missing[*]}" >&3
        return 1
    fi
}

@test "help_index: no menciona comandos ausentes del dispatch" {
    local extra=()
    local dispatch help_cmds cmd
    dispatch="$(_dispatch_cmds)"
    help_cmds="$(grep -oE '"(sudo )?wifi [a-z]+' "$REPO/lib/help_index.sh" \
                  | sed -E 's/.*wifi //' | sort -u)"

    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        if ! echo "$dispatch" | grep -qxF "$cmd"; then
            extra+=("$cmd")
        fi
    done <<< "$help_cmds"

    if [ "${#extra[@]}" -gt 0 ]; then
        printf 'extra en help_index: %s\n' "${extra[*]}" >&3
        return 1
    fi
}

@test "help_index: imprime sin error y contiene categorias" {
    run help_index
    [ "$status" -eq 0 ]
    echo "$output" | grep -qiE 'ESTADO|ANTENAS|REDES'
}
