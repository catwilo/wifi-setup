# wifi-setup

WiFi + LAN + VPN sobre NetworkManager para Debian 13+. Backbone unico:
NetworkManager. Fallback: iwd con DHCP integrado (`wifi fallback on`).

Soporta dos antenas simultaneas -- nativa (PCI) y USB externa -- con
perfiles y prioridades independientes por antena.

## Instalacion

    sudo bash install.sh

Auto-detecta antenas (USB=PRIMARY, nativa=SECONDARY), pregunta SSID/PSK
si no hay perfiles previos, y deja NM como gestor de red, iwd como
fallback manual (parado, activable con `wifi fallback on`), SSH
hardened en el puerto 22, y Tailscale instalado y apagado. Relanza en
tmux para sobrevivir cortes de SSH durante el install.

El cable LAN NO se configura en el install: usa `wifi lan setup` cuando
lo necesites.

## Uso rapido

    sudo wifi status                 # NM + antenas + conexiones + LAN + VPN + internet
    sudo wifi ifaces                 # inventario fisico de antenas
    sudo wifi scan                   # escaneo: SSIDs entre comillas
    sudo wifi add                    # picker fzf sobre el ultimo scan
    sudo wifi add <ssid>             # crear perfil directo (PSK interactivo)
    sudo wifi networks               # tabla unificada del store de redes
    sudo wifi radio list             # rol y estado por antena
    sudo wifi fallback status        # quien maneja WiFi: NM o iwd
    sudo wifi doctor                 # diagnostico read-only del stack

Cada subcomando acepta `-h`/`--help` para su ayuda detallada:

    wifi scan -h
    wifi lan -h
    wifi vpn -h

## Subcomandos

### Estado (solo lectura, no requieren root)

    wifi status          NM, antenas, conexiones, LAN, VPN, internet
    wifi ifaces          inventario fisico: kernel + NM + huerfanos
    wifi scan [--iface X]  escaneo: SSIDs entre comillas (visibilidad de espacios)
    wifi networks        tabla unificada del store de redes
    wifi showmac <profile>  MAC clonada del perfil
    wifi lan status      estado del perfil LAN
    wifi vpn status      estado y peers de Tailscale
    wifi monitor status  iface por modo (managed/monitor)
    wifi doctor          reporte del stack
    wifi version         version del stack
    wifi help            ayuda top-level

### Antenas (WiFi, nativa + USB, requieren root)

    sudo wifi radio list              tabla: iface, tipo, estado, conexion, rol
    sudo wifi radio primary <i>       persistente: i pasa a PRIMARY
    sudo wifi radio secondary <i>     persistente: i pasa a SECONDARY
    sudo wifi radio use <i>           solo esta sesion (no persiste)
    sudo wifi radio clear-session     olvida override de sesion
    sudo wifi radio up <i>            activa la antena
    sudo wifi radio down <i>          desactiva la antena

    El sufijo --persist en up/down tambien persiste el cambio de
    autoconnect. Sin el, el cambio vive solo hasta el proximo boot.

### Redes WiFi (perfiles y store)

    sudo wifi add [<ssid>] [--iface X] [--pass P]  crear (picker fzf sin <ssid>)
    sudo wifi switch <ssid> [iface]                activar perfil guardado
    sudo wifi passwd <profile|ssid> [--pass P]     cambiar PSK (reconecta)
    sudo wifi showpass <profile>                   mostrar PSK en claro
    sudo wifi autoconnect <profile> <on|off>       autoconnect manual

    sudo wifi networks list          tabla del store (SSID, iface, auto, prio, NM, IWD)
    sudo wifi networks show <ssid>   ficha completa de un SSID (PSK, filas, NM, IWD)
    sudo wifi networks merge         fundir perfiles NM al store (aditivo)
    sudo wifi networks sync          regenerar perfiles NM desde el store
    sudo wifi networks import-iwd    importar redes de iwd al store (read-only)
    sudo wifi networks export <p>    backup del store a <p>
    sudo wifi networks import <p>    merge desde <p> (aditivo)
    sudo wifi networks prune         eliminar filas huerfanas (con confirmacion)

    sudo wifi rename <actual> <nuevo>    renombrar un perfil NM
    sudo wifi setpriority <ssid|perfil> <N>   cambiar prioridad de autoconnect
    sudo wifi delete <ssid|perfil>       borrar perfil + filas de la DB
    sudo wifi showpass <ssid|perfil>     ver PSK (DB -> NM -> iwd)

### MAC

    sudo wifi setmac <profile> <mac|random|stable|permanent>
    wifi showmac <profile>

### USB Naming (MAC -> nombre de iface)

    wifi usb-names              ver mappings y estado del .link
    sudo wifi usb-names apply   escribir/actualizar los .link (proximo boot)
    sudo wifi usb-names edit    editar config/usb-names.conf

### LAN (cable ethernet, activacion manual)

    sudo wifi lan setup server --ip 1.2.3.2/24  IP estatica + NAT
    sudo wifi lan setup client --ip 1.2.3.1/24 --gw 1.2.3.2
    sudo wifi lan setup router                  DHCP del router, sin NAT
    sudo wifi lan setup auto                    DHCP, sin configuracion
    sudo wifi lan up                            activar
    sudo wifi lan down                          desactivar
    wifi lan status                             estado
    sudo wifi lan remove                        borrar perfil

    El perfil LAN existe con autoconnect=off: NO se activa hasta
    `wifi lan up`. Esto evita que el install cambie la ruta por defecto
    sin que el usuario lo pida.

### VPN (Tailscale)

    sudo wifi vpn install                    instalar + daemon (sin conectar)
    sudo wifi vpn up                         conectar
    sudo wifi vpn up --routes 1.2.3.0/24     conectar + anunciar subred
    sudo wifi vpn up --advertise-exit-node   conectar + exit node
    sudo wifi vpn down                       desconectar (daemon sigue)
    wifi vpn status                          estado y peers

### Modo monitor (por antena)

    sudo wifi monitor on <iface>    NM libera la iface; queda en monitor
    sudo wifi monitor off <iface>   vuelve a managed; NM reconecta
    wifi monitor status             estado por iface

    Si es la unica antena con conexion, ponerla en monitor corta el
    acceso remoto. El comando avisa pero no bloquea.

### Fallback (iwd vs NetworkManager)

    sudo wifi fallback on        pasa el control a iwd (NM parado)
    sudo wifi fallback off       vuelve a NetworkManager (iwd parado)
    wifi fallback status         quien esta al mando ahora

    iwd arranca con DHCP integrado (EnableNetworkConfiguration=true en
    /etc/iwd/main.conf). El estado previo de NM/iwd se guarda en
    fallback.state y se restaura con fallback off.

### Diagnostico y emergencia

    sudo wifi doctor [--fix]     reporte del stack (--fix aplica fixes seguros)
    sudo wifi panic              reinicia NM y reconecta todas las antenas

### Instalacion

    sudo bash install.sh         instala NM, perfiles, hardening, tailscale
    sudo bash uninstall.sh       desinstala (iwd queda instalado, parado)
    sudo bash checks.sh          verifica estado post-install

## Modelo

- **Antenas**: dos antenas WiFi pueden estar conectadas simultaneamente
  a redes distintas. PRIMARY/SECONDARY solo controlan la prioridad de
  ruta cuando ambas tienen internet. No implica apagar ninguna.
- **Store de redes**: `networks.tsv` es la fuente central y unica. Una
  fila por (ssid, iface). La PSK se guarda una vez por SSID y se propaga
  a todas las filas del mismo SSID y a ambos backends (NM keyfile y
  `/var/lib/iwd/<ssid>.psk`). `merge` es aditivo; `sync` regenera
  perfiles NM desde el store; `add` y `passwd` escriben en los dos
  backends de una vez.
- **iwd**: es el fallback manual del usuario. `wifi-setup` no lo
  gestiona: solo lo lee (`import-iwd`) y le escribe la PSK al agregar
  una red, para que el ciclo iwd <-> NM no pierda credenciales.
- **Persistencia**: STATE_DIR/install.state, radio.state, radio.session,
  lan.state, networks.tsv, fallback.state, last-scan.txt.
- **Ficheros de config**: CONFIG_DIR/usb-names.conf (mapeos MAC -> iface).

## Diagnostico

    bash checks.sh               verificacion post-install con PASS/FAIL
    sudo wifi doctor             reporte del stack (read-only)
    sudo wifi doctor --fix       aplica fixes seguros automaticamente

## Manuales

docs/nmcli-manual.md   repertorio nmcli para operar a mano cuando `wifi` no alcanza

## Arquitectura

Ver `ARCHITECTURE.md` para el mapa de modulos y las decisiones de diseno.

