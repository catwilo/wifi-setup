PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE block (
    id     TEXT PRIMARY KEY,
    title  TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending','wip','done')) DEFAULT 'pending'
);
INSERT INTO block VALUES('8','uplink failover','wip');
INSERT INTO block VALUES('7','rol cable LAN persistente (P1)','pending');
INSERT INTO block VALUES('3','comandos faltantes en bin/wifi','pending');
INSERT INTO block VALUES('6','noemap no descubre el equipo','pending');
INSERT INTO block VALUES('9','Arquitectura: mapa de archivos y responsabilidades','done');
CREATE TABLE item (
    block_id TEXT NOT NULL REFERENCES block(id),
    seq      INTEGER NOT NULL,
    text     TEXT NOT NULL,
    done     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (block_id, seq)
);
INSERT INTO item VALUES('8',0,'CODIGO EN MAIN (commit d965fa0). Verificado: hook desplegado, detect_ssh_iface devuelve wlx (proteccion OK), bug primary==fallback corregido',0);
INSERT INTO item VALUES('8',1,'FALTA: prueba de failover REAL (forzar NOCARRIER) -- requiere 2o acceso (cable directo o consola fisica) porque por wlx el apagado de la iface SSH se auto-bloquea y no es representativo',0);
INSERT INTO item VALUES('8',2,'FALTA: validar que install.sh copia el hook desde cero',0);
INSERT INTO item VALUES('7',0,'lan-role.conf en STATE_DIR, comando ''wifi lan <modo>''. Sin empezar',0);
INSERT INTO item VALUES('3',0,'add/networks/switch, fallback idempotente, status. Sin empezar',0);
INSERT INTO item VALUES('6',0,'subred 1.2.3.0/24 vs escaner / sshd iface / firewall. Sin empezar',0);
INSERT INTO item VALUES('9',0,'FLUJO: bin/wifi (entrypoint unico) -> install.sh|uninstall.sh|checks.sh -> source de lib/*.sh segun comando',0);
INSERT INTO item VALUES('9',1,'bin/wifi -- dispatcher CLI unico. 23 subcomandos (install/status/add/switch/useif/setmac/uplink/lan/etc). Todo el resto se invoca via ''sudo wifi <cmd>'' una vez instalado',0);
INSERT INTO item VALUES('9',2,'install.sh -- instalador principal. Auto-detecta modo server/client, interfaces, corre en ventana byobu (supervivencia SSH), limpia instalacion previa, escribe systemd units, guarda install.state',0);
INSERT INTO item VALUES('9',3,'uninstall.sh -- desinstalador. Confirmacion interactiva, detiene servicios, limpia NAT dirigido (fix #15), pregunta si borrar /opt/wifi-setup',0);
INSERT INTO item VALUES('9',4,'checks.sh -- diagnostico post-install. Lee install.state, corre checks comunes (SSH/Tailscale/internet/DNS) + especificos por modo server/client, hints causa/fix por cada fallo',0);
INSERT INTO item VALUES('9',5,'lib/log.sh -- logging base: niveles ok/warn/err/info/step, spinner TTY-aware, escribe a archivo sin ANSI. Todo lo demas depende de esto',0);
INSERT INTO item VALUES('9',6,'lib/common.sh -- base compartida obligatoria (source primero en todo script). Define BASE_DIR/STATE_DIR/CONFIG_DIR, log()/die(), require_root, validate_interface, backup_file/rollback_network, sweep_legacy_install',0);
INSERT INTO item VALUES('9',7,'lib/deps.sh -- instala paquetes apt segun modo (wpasupplicant/iptables/systemd/etc). Usado solo por install.sh',0);
INSERT INTO item VALUES('9',8,'lib/detect.sh -- deteccion NO destructiva (solo lee): interfaz SSH activa, IP local SSH. Usado por install.sh, useif, uplink, lan para no cortar el acceso',0);
INSERT INTO item VALUES('9',9,'lib/net.sh -- interfaces wifi/usb/plan + CRUD de bloques network={} en wpa_supplicant.conf preservando lo demas. Usado por bin/wifi (add/switch/band/networks) e install.sh',0);
INSERT INTO item VALUES('9',10,'lib/forward.sh -- IP estatica, NAT/forwarding, MAC persistente Windows-like. set_mac_hot tiene rollback completo; apply_persistent_mac_link/setup_upstream_dhcpcd (camino automatico) NO (fix pendiente #16)',0);
INSERT INTO item VALUES('9',11,'lib/lan.sh -- rol del cable LAN (server/client/router), unit systemd propio. Duplica NAT de forward.sh de forma inline (decision pendiente #17)',0);
INSERT INTO item VALUES('9',12,'lib/uplink.sh -- failover PRIMARY/FALLBACK no-preemptivo via eventos carrier (no polling). Persiste en uplink-role.conf. Disparado por el hook dhcpcd',0);
INSERT INTO item VALUES('9',13,'lib/survival.sh -- mantiene vivo el install si cae el SSH, usando byobu/tmux como ventana de primer plano. Solo usado por install.sh',0);
INSERT INTO item VALUES('9',14,'lib/ssh.sh -- hardening SSH (puerto 22, cripto moderna, keepalive). Valida config con sshd -t antes de reiniciar, revierte si es invalida',0);
INSERT INTO item VALUES('9',15,'lib/tailscale.sh -- instala Tailscale, lo deja activo pero SIN conectar (requiere ''tailscale up'' manual)',0);
INSERT INTO item VALUES('9',16,'dhcpcd-hooks/90-wifi-setup-uplink -- hook invocado por dhcpcd en NOCARRIER, llama a ''wifi uplink-event''. Ignora a proposito NOCARRIER_ROAMING (evita falsos positivos)',0);
INSERT INTO item VALUES('9',17,'PRIORIDAD actual (miko next --all): #15 P1 DONE (este fix) -- #16 P1 pendiente (rollback MAC automatico) -- #7/#19-instalacion P1 pendiente (instalar fix en nodos) -- #17 P2 pendiente (decision diseno NAT duplicado) -- #3/#6 P1 sin empezar (comandos faltantes bin/wifi, noemap)',0);
CREATE TABLE doc (
    id     TEXT PRIMARY KEY,
    kind   TEXT NOT NULL CHECK (kind IN ('ADR','MTS','STD','RFC','VOC')),
    title  TEXT NOT NULL,
    status TEXT NOT NULL
);
CREATE TABLE doc_field (
    doc_id  TEXT NOT NULL REFERENCES doc(id),
    name    TEXT NOT NULL,
    content TEXT NOT NULL,
    PRIMARY KEY (doc_id, name)
);
CREATE TABLE doc_rule (
    doc_id TEXT NOT NULL REFERENCES doc(id),
    seq    INTEGER NOT NULL,
    modal  TEXT NOT NULL CHECK (modal IN ('MUST','MUST_NOT','SHOULD','MAY')),
    text   TEXT NOT NULL,
    PRIMARY KEY (doc_id, seq)
);
CREATE TABLE doc_ref (
    from_id TEXT NOT NULL REFERENCES doc(id),
    to_id   TEXT NOT NULL REFERENCES doc(id),
    rel     TEXT NOT NULL CHECK (rel IN ('depends_on','references')),
    PRIMARY KEY (from_id, to_id, rel)
);
CREATE TABLE decision (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    seq     INTEGER NOT NULL,
    text    TEXT NOT NULL,
    adr_ref TEXT REFERENCES doc(id)
);
CREATE TABLE roadmap_phase (
    id             INTEGER PRIMARY KEY,
    title          TEXT NOT NULL,
    status         TEXT NOT NULL CHECK (status IN ('pending','done')) DEFAULT 'pending',
    depends_on_doc TEXT REFERENCES doc(id)
);
CREATE TABLE roadmap_item (
    phase_id INTEGER NOT NULL REFERENCES roadmap_phase(id),
    seq      INTEGER NOT NULL,
    text     TEXT NOT NULL,
    done     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (phase_id, seq)
);
CREATE TABLE prose_section (
    source  TEXT NOT NULL CHECK (source IN ('terminology','authoring','contributing')),
    seq     INTEGER NOT NULL,
    section TEXT NOT NULL,
    text    TEXT NOT NULL,
    PRIMARY KEY (source, seq)
);
COMMIT;
