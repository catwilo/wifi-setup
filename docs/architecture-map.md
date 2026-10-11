# wifi-setup -- Architecture

## Stack

    NetworkManager         WiFi + ethernet + DHCP + NAT (backbone)
    wpa_supplicant         backend WiFi de NM (por defecto)
    iwd                    fallback manual (instalado, parado, disabled)
    Tailscale              VPN (instalado, apagado hasta `wifi vpn up`)

No se usa: dhcpcd, systemd-networkd, NetworkManager plugins externos.

## Capas

    bin/wifi            dispatcher CLI puro
        -> install.sh | uninstall.sh | checks.sh
        -> source lib/*.sh segun subcomando
        -> lib/*.sh llaman nmcli

`bin/wifi` no ejecuta logica de negocio: cada `_cmd_*` valida args,
sourcea el lib correspondiente, llama una funcion, imprime resultado.

## Responsabilidades por archivo

### Raiz

    bin/wifi            Dispatcher. Solo parse + dispatch. Sin logica real.
    install.sh          Instalador. Instala stack, crea perfiles, no activa LAN/VPN.
    uninstall.sh        Desinstalador. Revierte install sin tocar perfiles NM.
    checks.sh           Verificacion post-install (read-only).
    .shellcheckrc       Disables justificados (SC1091 path dinamico, SC2034 globals).

### lib/

    common.sh           Bootstrap obligatorio: set -Eeuo, dirs, colores,
                        source log.sh + safe.sh, die/require_root/require_dirs,
                        validate_interface, backup_file, sweep_legacy_install.

    log.sh              Output: ok/warn/err/info/section/step. Todo a stderr
                        + archivo sin ANSI.

    safe.sh             Proteccion contra perdida de acceso remoto:
                        snapshot + canary + watchdog + rollback automatico.
                        Toda operacion critica pasa por safe_run. Configurable
                        (canary default 100.103.104.19, timeout por operacion).

    detect.sh           Deteccion no destructiva: SSH iface + local IP.

    nm.sh               Wrapper fino sobre nmcli. Ningun otro modulo llama
                        nmcli directo. Si NM cambia su interfaz, se ajusta aqui.

    radio.sh            Antenas WiFi (nativa + USB). Roles primary/secondary
                        (persistente) + override de sesion. Up/down con safe_run.

    lan.sh              Cable ethernet. Perfiles NM (manual/shared/auto) con
                        autoconnect=off. Activacion manual con `wifi lan up`.

    vpn.sh              Tailscale: install + up/down/status + routes.
                        install.sh deja el daemon activo sin conectar.

    ssh.sh              Hardening SSH con rollback si sshd -t falla.

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
    wifi radio *        antenas: list/primary/secondary/use/up/down
    wifi add <ssid>     crear perfil WiFi en la antena activa
    wifi switch <ssid>  activar perfil guardado
    wifi lan setup ...  crear perfil del cable (NO activar)
    wifi lan up|down    activar/desactivar perfil LAN
    wifi vpn up|down    conectar/desconectar Tailscale
    wifi panic          reiniciar NM + reconectar antenas
    wifi safe log       historico de operaciones criticas

## Seguridad remota (safe_run)

Toda operacion que pueda cortar acceso SSH pasa por `safe_run <label> <timeout> <cmd...>`:

    1. Snapshot: guarda perfiles NM, wpa_supplicant, rutas, servicios.
    2. Canary: watchdog en background pinguea <canary> cada 2s.
    3. Aplicar: corre el comando.
    4. Esperar <timeout> segundos.
    5. Si el canary falla 3 veces seguidas: rollback automatico.
    6. Si sobrevive <timeout>: exito, canary se detiene.

Configuracion:
    - canary default: 100.103.104.19 (persistible con `wifi canary set`)
    - timeout: por operacion (radio up=60, radio down=45, lan up=75, etc.)
    - logs: BASE_DIR/logs/ops.log
    - snapshots: BASE_DIR/state/snapshots/

## Persistencia

    STATE_DIR/install.state         iface primaria/secundaria, ssh iface
    STATE_DIR/radio.state           RADIO_PRIMARY, RADIO_SECONDARY
    STATE_DIR/radio.session         SESSION_OVERRIDE (no persiste)
    STATE_DIR/lan.state             LAN_IFACE, LAN_MODE, LAN_IP, LAN_GW
    CONFIG_DIR/canary.default       canary IP o alias
    LOG_DIR/wifi-setup.log          log general
    LOG_DIR/ops.log                 historico de operaciones safe
    LOG_DIR/uplink-hook.log         (legacy, ya no se escribe)

## Decisiones no obvias

### Por que NetworkManager y no iwd + dhcpcd

NM resuelve nativo todo lo que el modelo anterior hacia a mano: gestion de
multiples interfaces, perfiles por red con prioridad, DHCP por iface, MAC
clonada, NAT (`ipv4.method shared`), IP estatica (`ipv4.method manual`).
iwd queda instalado, parado, disabled -- fallback manual si NM falla.

### Por que safe_run con canary a un nodo externo

Los comandos se mandan por nssh via Tailscale. Si un cambio rompe WiFi o
rutas, la sesion SSH muere y no hay forma de mandar "rollback". El canary
pinguea un nodo externo (tx1 por defecto): si tx1 deja de responder 3 veces
seguidas, el watchdog asume que perdimos acceso y restaura el snapshot sin
esperar ordenes. La sesion vuelve sola cuando el acceso se restablece.

### Por que timeout por operacion y no global

Subir una antena puede tardar 5s; subir una LAN con NAT + DHCP + verificacion
puede tardar 60s. Un timeout unico seria o muy corto (rollback innecesario)
o muy largo (esperas largas cuando hay fallo real). Cada comando define su
default apropiado, siempre override con `--timeout N`.

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
de apagar una antena, y siempre con `safe_run`.
