# wifi-setup — Bloques de contexto pendientes (recuperado de ctx-archive.sql)

## Bloque 8: uplink failover (wip)
- CODIGO EN MAIN (commit d965fa0). Verificado: hook desplegado, detect_ssh_iface devuelve wlx (proteccion OK), bug primary==fallback corregido.
- FALTA: prueba de failover REAL (forzar NOCARRIER) -- requiere 2o acceso (cable directo o consola fisica) porque por wlx el apagado de la iface SSH se auto-bloquea y no es representativo.
- FALTA: validar que install.sh copia el hook desde cero.

## Bloque 7: rol cable LAN persistente (P1) (pending)
- lan-role.conf en STATE_DIR, comando 'wifi lan <modo>'. Sin empezar.

## Bloque 3: comandos faltantes en bin/wifi (pending)
- add/networks/switch, fallback idempotente, status. Sin empezar.

## Bloque 6: noemap no descubre el equipo (pending)
- subred 1.2.3.0/24 vs escaner / sshd iface / firewall. Sin empezar.

---
*Recuperado del ctx-archive.sql (bloques 3,6,7,8) de este repo, sesion 2026-08-29. Bloque 9 (arquitectura) ya migrado a docs/architecture-map.md.*
