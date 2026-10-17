# wifi-setup -- Architecture

## Stack

    NetworkManager         WiFi + ethernet + DHCP + NAT (backbone)
    wpa_supplicant         backend WiFi de NM (por defecto)
    iwd                    fallback con DHCP integrado (`wifi fallback on`)
    Tailscale              VPN (instalado, apagado hasta `wifi vpn up`)
    Tailscale              VPN (instalado, apagado hasta `wifi vpn up`)

En modo backbone no se usa dhcpcd ni systemd-networkd. En modo fallback
(`wifi fallback on`) iwd hace DHCP por si mismo -- DHCP integrado via
EnableNetworkConfiguration=true en /etc/iwd/main.conf.
No se usa: dhcpcd, systemd-networkd, NetworkManager plugins externos.

## Capas

    bin/wifi            dispatcher CLI puro
        -> install.sh | uninstall.sh | checks.sh
        -> source lib/*.sh segun subcomando
        -> source lib/help.sh cuando se pide -h
        -> lib/*.sh llaman nmcli

`bin/wifi` no ejecuta logica de negocio: cada `_cmd_*` valida args,
sourcea el lib correspondiente, llama una funcion, imprime resultado.
La ayuda vive en lib/help.sh (una funcion help_<sub> por subcomando);
`_maybe_help <topic> "$@"` en cada `_cmd_*` intercepta `-h`/`--help`
antes de tocar libs de negocio.

## Responsabilidades por archivo

### Raiz

    bin/wifi            Dispatcher. Solo parse + dispatch. Sin logica real.
    install.sh          Instalador. Instala stack, crea perfiles, no activa LAN/VPN.
    uninstall.sh        Desinstalador. Revierte install sin tocar perfiles NM.
    checks.sh           Verificacion post-install (read-only).
    README.md           Guia de uso (subcomandos, modelo, estado conocido).
    .shellcheckrc       Disables justificados (SC1091 path dinamico, SC2034 globals).

### lib/

    common.sh           Bootstrap obligatorio: set -Eeuo, dirs, colores,
                        source log.sh, die/require_root/require_dirs,
                        validate_interface, backup_file, sweep_legacy_install.

    log.sh              Output: ok/warn/err/info/section/step. Todo a stderr
                        + archivo sin ANSI.

    help.sh             Help modular. Paleta por categoria (STATE/RADIO/NET/
                        MAC/USB/LAN/VPN/MONITOR/DIAG/EMERG) y una funcion
                        help_<sub> por subcomando. Primero y unico lugar
                        que define el texto de ayuda.

    detect.sh           Deteccion no destructiva: SSH iface + local IP.

    nm.sh               Wrapper fino sobre nmcli. Ningun otro modulo llama
                        nmcli directo (salvo scan.sh, que usa
                        `nmcli dev wifi list --rescan yes` porque no hay
                        wrapper para escaneo). Si NM cambia su interfaz,
                        se ajusta aqui.

    radio.sh            Antenas WiFi (nativa + USB). Roles primary/secondary
                        (persistente) + override de sesion.

    scan.sh             Escaneo de redes WiFi visibles. Solo lectura: dispara
                        rescan (nmcli dev wifi list --rescan yes) y lista.
                        No crea perfiles, no conecta, no toca estado.
                        Los SSID se imprimen entre comillas dobles (--names
                        y last-scan.txt) para hacer visibles los espacios al
                        inicio/fin; _add_pick_ssid despoja las comillas al
                        elegir.
                        No crea perfiles, no conecta, no toca estado.

    networks.sh         Store central y UNICO de redes WiFi. TSV con una
                        fila por (ssid, iface). Fuente de verdad: add y
                        passwd escriben aqui primero, luego propagan a
                        NM (keyfile) e iwd (/var/lib/iwd/<ssid>.psk).
                        merge/import-iwd alimentan la DB; sync/apply
                        propagan a los backends; export/import mueven la
                        DB entre equipos; prune limpia filas huerfanas.

    lan.sh              Cable ethernet. Perfiles NM (manual/shared/auto) con
                        autoconnect=off. Activacion manual con `wifi lan up`.

    vpn.sh              Tailscale: install + up/down/status + routes.
                        install.sh deja el daemon activo sin conectar.

    ssh.sh              Hardening SSH con rollback si sshd -t falla.

    deps.sh             Instalacion apt: NetworkManager + iwd + utilidades.

    fallback.sh         Alterna entre NM (backbone) e iwd (fallback con DHCP
                        integrado). fallback_on/off/status. Guarda el estado
                        previo en fallback.state para restauracion exacta.
    deps.sh             Instalacion apt: NetworkManager + iwd + utilidades.

## Flujo de `install.sh`

    require_root
    -> relaunch en tmux 'wifi-setup' (supervivencia SSH)
    -> limpieza previa (idempotente)
    -> deteccion: SSH iface + antenas WiFi (USB=PRIMARY, nativa=SECONDARY)
    -> install_deps (NM + iwd + utilities)
    -> migracion stack: stop iwd/dhcpcd/networkd, start NM
    -> prompts SSID/PSK (solo si no hay perfiles previos)
    -> crear perfiles NM por antena + persistir roles
    -> configure_ssh
    -> vpn_install (daemon activo, sin conectar)
    -> symlink /usr/local/bin/wifi -> repo/bin/wifi
    -> guardar install.state + checks.sh

NO configura el cable LAN (eso es `wifi lan setup`).
NO conecta Tailscale (eso es `wifi vpn up`).

## Flujo de `wifi <cmd>` (runtime)

    wifi status         NM + antenas + conexiones + LAN + VPN + internet
    wifi ifaces         inventario fisico de antenas (kernel + NM)
    wifi scan [--iface X]  escaneo de redes visibles ahora
    wifi radio *        antenas: list/primary/secondary/use/up/down
    wifi add [<ssid>]   crear perfil + conectar (picker fzf sin <ssid>)
    wifi networks *     store: list/show/merge/sync/import-iwd/export/import/prune
    wifi rename         renombrar un perfil NM
    wifi setpriority    cambiar prioridad de autoconnect
    wifi delete         borrar un perfil + filas de la DB
    wifi showpass       ver PSK (DB -> NM -> iwd)
    wifi switch <ssid>  activar perfil guardado
    wifi passwd <profile|ssid>  cambiar PSK y reconectar
    wifi fallback *     alternar NM (backbone) e iwd (fallback)
    wifi lan setup ...  crear perfil del cable (NO activar)
    wifi lan up|down    activar/desactivar perfil LAN
    wifi vpn up|down    conectar/desconectar Tailscale
    wifi monitor on|off cambiar iface a/desde modo monitor
    wifi doctor [--fix] diagnostico + auto-fix
    wifi panic          reiniciar NM + reconectar antenas
    wifi panic          reiniciar NM + reconectar antenas

Cada subcomando acepta -h/--help. El dispatcher entrega el control a
lib/help.sh antes de tocar el lib de negocio.


## Persistencia

    STATE_DIR/install.state         iface primaria/secundaria, ssh iface
    STATE_DIR/radio.state           RADIO_PRIMARY, RADIO_SECONDARY
    STATE_DIR/radio.session         SESSION_OVERRIDE (no persiste)
    STATE_DIR/lan.state             LAN_IFACE, LAN_MODE, LAN_IP, LAN_GW
    STATE_DIR/networks.tsv          store central de redes WiFi
    STATE_DIR/fallback.state        estado previo de NM/iwd antes de fallback_on
    STATE_DIR/last-scan.txt         lista de SSID del ultimo scan (con comillas)
    CONFIG_DIR/usb-names.conf       mapeos MAC -> nombre de iface USB
    LOG_DIR/wifi-setup.log          log general
    LOG_DIR/wifi-setup.log          log general

## Decisiones no obvias

### Por que NetworkManager y no iwd + dhcpcd

NM resuelve nativo todo lo que el modelo anterior hacia a mano: gestion de
multiples interfaces, perfiles por red con prioridad, DHCP por iface, MAC
clonada, NAT (`ipv4.method shared`), IP estatica (`ipv4.method manual`).
iwd queda instalado, parado, disabled -- fallback manual si NM falla.


### Por que installer NO activa el cable LAN

El cable LAN sirve para conectar a OTRO equipo (compartir internet o red
directa). Si el instalador lo activara automaticamente, cambiaria la ruta
default del equipo sin que el usuario lo pida, potencialmente rompiendo el
acceso SSH. Con `autoconnect=off` el perfil existe pero no molesta hasta
que el usuario hace `wifi lan up`.

### Por que installer NO conecta Tailscale

`tailscale up` requiere autenticacion interactiva (URL + navegador) y
expone el nodo a la red del tailnet. Debe ser una decision explicita del
usuario, no un efecto secundario del instalador.

### Por que los roles de antena son solo prioridad

Tener dos antenas WiFi no significa que una deba estar apagada. Ambas
pueden estar conectadas a redes distintas simultaneamente (una a la red de
casa, otra a un hotspot). PRIMARY/SECONDARY solo controla la prioridad
de ruta cuando ambas tienen internet. `wifi radio down` es la unica forma
de apagar una antena.

### Por que help modular en lib/help.sh

El help top-level vivia antes como heredoc dentro de bin/wifi: tocarlo
implicaba editar el dispatcher. Ahora bin/wifi solo enruta; lib/help.sh
concentra todo el texto y agrega `help_<sub>` por subcomando. El
resultado: `wifi <sub> -h` funciona para cada subcomando sin tocar la
logica, y colorear el help (por categoria) no mezcla presentacion con
dispatch.

### Por que iwd hace su propio DHCP en fallback

En modo backbone, NM gestiona DHCP por iface. En modo fallback, con NM
enmascarado, no hay quien asigne IP por DHCP -- salvo iwd. La directiva
EnableNetworkConfiguration=true en /etc/iwd/main.conf habilita el cliente
DHCP integrado de iwd. `fallback_on` la escribe si falta, preservando el
resto del archivo. `_fallback_wait_ip` confirma la asignacion y avisa si
iwd no conoce la red (requiere `iwctl station <iface> connect <ssid>`).
dispatch.
