# wifi-setup -- Architecture

## Stack

    NetworkManager      WiFi + DHCP + DNS (backbone)
    iwd                 fallback con DHCP integrado (`wifi fallback on`)
    systemd-resolved    DNS stub (127.0.0.53), dueno de /etc/resolv.conf
    wl (broadcom-sta)   driver Broadcom, requerido en BCM4313/BCM4727

NM es el gestor por defecto. iwd solo via `wifi fallback on`.
No se usa: dhcpcd, systemd-networkd, wpa_supplicant directo.

## Capas

    bin/wifi            preamble (log, symlink, _load, _maybe_help) + dispatch
        -> source lib/cli_commands.sh (los _cmd_*)
        -> _cmd_* sourcea el lib del dominio y llama
        -> lib/*.sh llama nmcli / iwctl / iw

`bin/wifi` no ejecuta logica de negocio: cada `_cmd_*` parsea args,
sourcea el lib del dominio, llama una funcion, imprime resultado. La
ayuda vive en `lib/help_*.sh`.

## Responsabilidades por archivo

### Raiz

    bin/wifi            Preamble + dispatch. Sin logica real.
    install.sh          Instala stack, symlink, units. No activa red.
    uninstall.sh        Revierte install sin tocar perfiles NM.
    checks.sh           Verificacion post-install (read-only).
    README.md           Guia de uso.
    ARCHITECTURE.md     Este documento.

### lib/

    common.sh           Bootstrap: set -Eeuo, dirs, colores, die, require_root.
    log.sh              ok/warn/err/info/section/step. stderr + archivo sin ANSI.

    nm.sh               Wrapper nmcli. Ningun otro modulo llama nmcli directo.
    deps.sh             apt: NM + iwd + utilidades.
    detect.sh           Deteccion no destructiva: SSH iface + IP local.

    radio_state.sh      Estado de antenas: load/save/session + helpers de kernel.
    radio_roles.sh      PRIMARY/SECONDARY/session, list, apply_autoconnect.
    radio_ops.sh        up/down/boot + inventario fisico (ifaces_list).

    networks_store.sh   TSV networks.tsv: init/rows/upsert/delete/update_field/psk.
    networks_pull.sh    pull nm / pull iwd (fundir al store).
    networks_apply.sh   Regenerar perfiles NM + escribir .psk iwd.
    networks_show.sh    list/show/export/import/cleanup.

    profiles.sh         CRUD de perfiles: add, password, rename, priority,
                        delete, autoconnect.

    scan.sh             Escaneo read-only. SSID entre comillas (visibilidad).
    fallback_state.sh   svc_snapshot, ensure_iwd_netconf, wait_ip, fix_routes.
    fallback_ops.sh     fallback_on/off/status.
    ssh.sh              Hardening SSH con rollback si sshd -t falla.
    status.sh           status_run: reporte completo del stack.

    help_index.sh       Help top-level (wifi help).
    help_wifi.sh        Ayuda: status, scan, add, radio.
    help_networks.sh    Ayuda: networks, connect, password, profile, priority,
                        delete, mac, autoconnect.
    help_system.sh      Ayuda: usb, fallback, ssh, clean, version.
    help.sh             Hub: sourcea los 4 help_*.sh.

    cli_commands.sh     Los _cmd_* (parseo de args + llamada al dominio).

## Flujo de `install.sh`

    require_root
    -> relaunch en tmux (supervivencia SSH)
    -> deteccion: SSH iface + antenas (USB=PRIMARY, nativa=SECONDARY)
    -> install_deps (NM + iwd + utilidades + systemd-resolved)
    -> _deps_ensure_resolved (systemd-resolved enabled, symlink resolv.conf)
    -> si NM no esta activo: unmask + start
    -> prompts SSID/PSK si no hay perfiles previos
    -> crear perfiles NM por antena + persistir roles
    -> radio_apply_autoconnect (PRIMARY=yes, SECONDARY=no)
    -> migracion stack: stop iwd/dhcpcd/networkd, start NM
    -> configure_ssh
    -> symlink /usr/local/bin/wifi -> repo/bin/wifi
    -> guardar install.state + checks.sh

install.sh no activa red que no este ya configurada. No configura LAN,
VPN ni tailscale -- esas areas no son parte del repo.

## Flujo de `wifi <cmd>` (runtime)

    wifi status           gestor + antenas + conexiones + internet
    wifi scan [--iface X] escaneo de redes visibles
    wifi radio *          list/primary/secondary/use/session/up/down/boot
    wifi add [<ssid>]     crear perfil + conectar (picker fzf sin <ssid>)
    wifi networks *       store: list/show/pull nm|iwd/export/import/cleanup
    wifi connect <ssid>   activar perfil guardado (nm_device_connect)
    wifi profile rename   renombrar perfil NM
    wifi priority set     prioridad de autoconnect
    wifi autoconnect set  override manual de autoconnect
    wifi delete           borrar perfil + filas de la DB
    wifi password show    ver PSK (NM -> DB -> iwd)
    wifi password set     cambiar PSK y reconectar
    wifi mac set|show     clonar o ver MAC por perfil
    wifi usb *            rename USB por MAC
    wifi fallback *       alternar NM (backbone) e iwd
    wifi ssh *            hardening SSH
    wifi clean            limpieza de residuos

Cada subcomando acepta -h/--help. El dispatcher entrega el control a
`lib/help_*.sh` antes de tocar el lib de negocio.

## Persistencia

    STATE_DIR/install.state         iface primaria/secundaria, ssh iface
    STATE_DIR/radio.state           RADIO_PRIMARY, RADIO_SECONDARY
    STATE_DIR/radio.session         SESSION_OVERRIDE (no persiste)
    STATE_DIR/networks.tsv          store central de redes WiFi
    STATE_DIR/fallback.state        estado previo NM/iwd antes de fallback_on
    STATE_DIR/last-scan.txt         lista de SSID del ultimo scan
    CONFIG_DIR/usb-names.conf       mapeos MAC -> iface USB
    LOG_DIR/wifi-setup.log          log general

## Decisiones no obvias

### Por que NetworkManager y no iwd + dhcpcd

NM resuelve nativo el modelo: multiples interfaces, perfiles por red con
prioridad, DHCP por iface, MAC clonada, IP estatica. iwd queda instalado,
parado, disabled -- fallback manual si NM falla.

### Por que los roles de antena son solo prioridad

Dos antenas pueden estar conectadas a redes distintas simultaneamente.
PRIMARY/SECONDARY solo controla la prioridad de ruta cuando ambas tienen
internet. `wifi radio down` es la unica forma de apagar una antena.

### Por que iwd hace su propio DHCP en fallback

Con NM enmascarado no hay quien asigne IP. `EnableNetworkConfiguration=true`
en `/etc/iwd/main.conf` habilita el cliente DHCP integrado. `fallback_on`
la escribe si falta. `_fallback_wait_ip` confirma la asignacion.

### Por que autoconnect lo decide el rol

`autoconnect=yes` es consecuencia del rol, no del perfil. PRIMARY -> `yes`;
SECONDARY -> `no`. Cambiar rol reescribe el campo. `wifi autoconnect set`
lo sobreescribe manualmente hasta el proximo cambio de rol.

### Por que `wl` y no `brcmsmac` (BCM4313 / BCM4727)

El driver open-source `brcmsmac` rompe HT en este chip. Sintomas:

    - dmesg: brcmsmac brcms_ops_bss_info_changed: disassociated (repetido)
    - dmesg: brcms_c_d11hdrs_mac80211: txop exceeded phylen 159/256 dur 1778/1504
    - iw dev <iface> station dump: tx retries > tx packets (125-150%),
      tx failed > 10%
    - ping -c30 -i0.2 <gw>: 15-30% loss sostenido, rtt max 300-1000ms
    - signal -22 a -47 dBm (antena sana, driver TX roto)
    - iw dev <iface> scan funciona (RX OK) pero TX no llega

No es antena danada: si el chip escanea 8+ APs y ve signal -22 dBm, el
front-end RF esta sano. El rate control del driver negocia MCS 3-7 y el
AP no recibe.

Diagnostico reproducible (cualquier boot):

    lspci -k -s 03:00.0 | grep "Kernel driver"
    iw dev <iface> station dump | grep -E 'tx retries|tx failed|signal'
    dmesg | grep -E 'brcmsmac|txop exceeded'

Verificar tambien que no haya supplicant duplicado: ps -eo comm | grep
wpa_supplicant debe estar vacio (iwd corre su propio supplicant D-Bus;
un wpa_supplicant del boot anterior pelea la iface y produce el mismo
sintoma).

Fix (probado):

    apt install -t trixie-backports linux-headers-"$(uname -r)" broadcom-sta-dkms

    /etc/modprobe.d/blacklist-brcm.conf:
        blacklist brcmsmac
        blacklist b43
        blacklist b43legacy
        blacklist ssb
        blacklist b44
        blacklist brcm80211
        blacklist brcmfmac

    NO blacklistear bcma: es el bus PCI, sin el wl no bindea y la
    antena desaparece en el proximo boot.

    modprobe -r brcmsmac b43 b43legacy ssb b44
    modprobe wl

Resultado post-fix (medido): 0% loss, 0 retries, 0 failed, signal -28
a -47 dBm, TX 65-72 Mbps. El chip se identifica como "Broadcom BCM4727
802.11 Hybrid Wireless Controller 6.30.223.271" con wl, no como
"BCM4313" con brcmsmac (lspci reportaba mal el modelo).

Trade-off: broadcom-sta tiene CVEs locales (CVE-2019-9501/9502/9503),
no remotos; requieren ejecucion previa en la maquina. Riesgo aceptable
frente a 25% de perdida constante. wl no soporta WPA3; si el AP pasa
a WPA3-only, la tarjeta no conecta y hay que evaluar bajar el AP a WPA2
mixed o asumir el 25% de perdida con brcmsmac.

## Entorno y operacion

- Repo vive en ~/unix-toolkit-tools/wifi-setup. Funciona en cualquier
  Debian 13+ con NetworkManager + iwd.
- Tests: bash tests/run.sh en la misma maquina. No requieren root.
- Instalar siempre con bash install.sh. No hay parches manuales ni
  symlinks manuales para reparar el estado.
- Diagnostico de un install fallido: leer
  ~/.local/state/wifi-setup/install-*.log.
- Antes de tocar drivers WiFi: lspci -k -s <bus>, iw dev <iface>
  station dump, dmesg | tail -40. Confirmar si es antena (signal
  bajo + scan vacio) o driver (signal alto + retries/failed altos).
