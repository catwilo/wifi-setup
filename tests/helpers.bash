# helpers.bash -- shared setup for wifi-setup BATS tests.
#
# wifi-setup manipula red/systemd/iptables en Debian. Esos flujos NO se
# pueden ejercitar en un entorno de prueba sin root ni en Termux. Los tests
# por diseno cubren:
#   - sintaxis y shellcheck (bash -n, shellcheck -x)
#   - guarda Debian (install/uninstall/check salen limpio fuera de Debian)
#   - --help de cada entrypoint
#   - invariantes de orden y estructura en install.sh (regresiones)
#   - config/usb-names.conf y comandos asociados
#   - ausencia de residuos del diseno viejo (safe_run, canary, /opt/wifi-setup)
#
# El REPO se lee del working tree real, no se copia: los tests son
# read-only y verifican el propio repo bajo prueba.

setup_env() {
    # HOME/XDG/TMPDIR aislados, por si algun test invoca scripts que
    # toquen rutas de usuario.
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$TMPDIR"

    # Apuntar al repo bajo prueba (el working tree, sin copia).
    export REPO="$BATS_TEST_DIRNAME/.."
    export INSTALL="$REPO/install.sh"
    export UNINSTALL="$REPO/uninstall.sh"
    export CHECKS="$REPO/checks.sh"
    export WIFI="$REPO/bin/wifi"
    export USB_CONF="$REPO/config/usb-names.conf"
}
