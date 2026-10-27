#!/usr/bin/env bats
# install.bats -- invariantes de install.sh con impacto real.

load helpers

setup() { setup_env; }

@test "install.sh: rechaza correr como root directo" {
    run grep -q 'install.sh debe correr como usuario, no como root' "$INSTALL"
    [ "$status" -eq 0 ]
}

@test "install.sh: PSK se pide dentro de _root_phase (no via argv)" {
    run grep -A250 '^_root_phase()' "$INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *'read -r -s -p "PSK'* ]]
}
