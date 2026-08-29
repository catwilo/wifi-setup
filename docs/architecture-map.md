# wifi-setup — Arquitectura: mapa de archivos y responsabilidades (recuperado de .ctx.db, bloque 9, done)

## Flujo general
bin/wifi (entrypoint unico) -> install.sh|uninstall.sh|checks.sh -> source de lib/*.sh segun comando.

## bin/wifi
Dispatcher CLI unico. 23 subcomandos (install/status/add/switch/useif/setmac/uplink/lan/etc). Todo el resto se invoca via "sudo wifi <cmd>" una vez instalado.

## install.sh
Instalador principal. Auto-detecta modo server/client, interfaces, corre en ventana byobu (supervivencia SSH), limpia instalacion previa, escribe systemd units, guarda install.state.

## uninstall.sh
Desinstalador. Confirmacion interactiva, detiene servicios, limpia NAT dirigido (fix #15), pregunta si borrar /opt/wifi-setup.

## checks.sh
Diagnostico post-install. Lee install.state, corre checks comunes (SSH/Tailscale/internet/DNS) + especificos por modo server/client, hints causa/fix por cada fallo.

## lib/log.sh
Logging base: niveles ok/warn/err/info/step, spinner TTY-aware, escribe a archivo sin ANSI. Todo lo demas depende de esto.

## lib/common.sh
Base compartida obligatoria (source primero en todo script). Define BASE_DIR/STATE_DIR/CONFIG_DIR, log()/die(), require_root, validate_interface, backup_file/rollback_network, sweep_legacy_install.

## lib/deps.sh
Instala paquetes apt segun modo (wpasupplicant/iptables/systemd/etc). Usado solo por install.sh.

## lib/detect.sh
Deteccion NO destructiva (solo lee): interfaz SSH activa, IP local SSH. Usado por install.sh, useif, uplink, lan para no cortar el acceso.

## lib/net.sh
Interfaces wifi/usb/plan + CRUD de bloques network={} en wpa_supplicant.conf preservando lo demas. Usado por bin/wifi (add/switch/band/networks) e install.sh.

## lib/forward.sh
IP estatica, NAT/forwarding, MAC persistente Windows-like. set_mac_hot tiene rollback completo; apply_persistent_mac_link/setup_upstream_dhcpcd (camino automatico) NO (fix pendiente #16).

## lib/lan.sh
Rol del cable LAN (server/client/router), unit systemd propio. Duplica NAT de forward.sh de forma inline (decision pendiente #17).

## lib/uplink.sh
Failover PRIMARY/FALLBACK no-preemptivo via eventos carrier (no polling). Persiste en uplink-role.conf. Disparado por el hook dhcpcd.

## lib/survival.sh
Mantiene vivo el install si cae el SSH, usando byobu/tmux como ventana de primer plano. Solo usado por install.sh.

## lib/ssh.sh
Hardening SSH (puerto 22, cripto moderna, keepalive). Valida config con sshd -t antes de reiniciar, revierte si es invalida.

## lib/tailscale.sh
Instala Tailscale, lo deja activo pero sin conectar (requiere "tailscale up" manual).

## dhcpcd-hooks/90-wifi-setup-uplink
Hook invocado por dhcpcd en NOCARRIER, llama a "wifi uplink-event". Ignora a proposito NOCARRIER_ROAMING (evita falsos positivos).

## Prioridad al momento de este snapshot (miko next --all)
#15 P1 DONE (fix de este bloque) -- #16 P1 pendiente (rollback MAC automatico) -- #7/#19-instalacion P1 pendiente (instalar fix en nodos) -- #17 P2 pendiente (decision diseno NAT duplicado) -- #3/#6 P1 sin empezar (comandos faltantes bin/wifi, noemap).

---
*Recuperado del .ctx.db original (bloque 9, status done) de este repo, sesion 2026-08-28. Ver ctx-archive.sql para el dump SQL completo.*
