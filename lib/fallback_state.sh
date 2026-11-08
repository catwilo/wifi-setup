#!/usr/bin/env bash
# lib/fallback.sh -- alterna entre NetworkManager (backbone) e iwd (fallback).
#
# RESPONSABILIDAD UNICA: apagar limpiamente NetworkManager y dejar iwd al
# mando con DHCP integrado, o revertir exactamente ese cambio.
#
# MODELO:
#   - fallback on:     para + enmascara NM, activa DHCP integrado de iwd
#                      (EnableNetworkConfiguration=true en /etc/iwd/main.conf),
#                      arranca + habilita iwd.
#   - fallback off:    para iwd, desenmascara + arranca NM.
#   - fallback status: reporta quien esta al mando ahora.
#
# Persistencia: STATE_DIR/fallback.state guarda el estado previo al "on"
# para que "off" restaure el estado original sin asumir nada.
#
# DHCP: iwd hace DHCP por si mismo cuando EnableNetworkConfiguration=true;
# no se necesita dhcpcd ni NM corriendo. Al volver a NM, NM toma su DHCP.
#
# Los perfiles NM NO se tocan: cuando NM vuelve, reconecta solo con ellos.
# iwd no ve esos perfiles; al arrancar por primera vez pide credenciales
# (iwctl) o espera configuracion. No se pierden credenciales.
#
# Requiere: common.sh + log.sh cargados antes.

FALLBACK_STATE="${STATE_DIR}/fallback.state"

# _fallback_svc_snapshot <svc> -- "active=X enabled=Y" compacto.
_fallback_svc_snapshot() {
    local svc="$1" active enabled
    active="$(systemctl is-active  "${svc}" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "${svc}" 2>/dev/null || true)"
    printf 'active=%s enabled=%s\n' "${active:-unknown}" "${enabled:-unknown}"
}

# _fallback_ensure_iwd_netconf -- garantiza que iwd haga DHCP por si mismo
# (sin dhcpcd ni NM corriendo). Escribe /etc/iwd/main.conf con la directiva
# EnableNetworkConfiguration=true. Idempotente: solo toca el archivo si
# falta la directiva. Preserva el resto de la config del usuario.
_fallback_ensure_iwd_netconf() {
    local conf="/etc/iwd/main.conf"
    local tmp
    mkdir -p /etc/iwd
    tmp="$(mktemp "${conf}.XXXXXX")"

    # Reescribe main.conf mergeando las claves canonicas en la PRIMERA
    # ocurrencia de cada seccion. El algoritmo anterior las anadia al
    # final del archivo, produciendo dos [General] (la primera vacia);
    # iwd lee solo la primera y descarta la segunda -> DHCP off -> sin IP
    # tras fallback on. Nuevo algoritmo: nunca duplica una seccion; si
    # no existe, la crea al final; si existe, inserta las claves dentro.
    # [DriverQuirks] DefaultInterface=?* impide que iwd destruya la
    # interfaz al pararse (systemctl stop iwd). Sin esto, el driver
    # borra wlan0 del kernel, NM arranca y no la ve, timeout. ?* es un
    # glob que matchea cualquier driver.
    python3 - "${conf}" "${tmp}" <<'PY_IWD_CONF'
import os, sys

src, dst = sys.argv[1], sys.argv[2]

CANONICAL = {
    "General": [("EnableNetworkConfiguration", "true")],
    "Network": [("NameResolvingService", "systemd")],
    "DriverQuirks": [("DefaultInterface", "?*")],
}
MANAGED_KEYS = {"EnableNetworkConfiguration", "NameResolvingService", "DefaultInterface"}

sections = []
cur_name, cur_lines = None, []
if os.path.exists(src):
    with open(src, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            s = line.strip()
            if s.startswith("[") and s.endswith("]"):
                if cur_name is not None or cur_lines:
                    sections.append((cur_name, cur_lines))
                cur_name, cur_lines = s[1:-1].strip(), []
            else:
                cur_lines.append(line)
    if cur_name is not None or cur_lines:
        sections.append((cur_name, cur_lines))

cleaned = []
for name, lines in sections:
    out = []
    for l in lines:
        s = l.strip()
        if not s or s.startswith("#"):
            out.append(l)
            continue
        key = s.split("=", 1)[0].strip()
        if key in MANAGED_KEYS:
            continue
        out.append(l)
    cleaned.append((name, out))

def find_first(name):
    for i, (n, _) in enumerate(cleaned):
        if n == name:
            return i
    return -1

for sec_name, kvs in CANONICAL.items():
    idx = find_first(sec_name)
    if idx == -1:
        cleaned.append((sec_name, [f"{k}={v}" for k, v in kvs]))
    else:
        n, lines = cleaned[idx]
        for k, v in kvs:
            lines.append(f"{k}={v}")
        cleaned[idx] = (n, lines)

with open(dst, "w", encoding="utf-8") as f:
    for name, lines in cleaned:
        if not any(l.strip() for l in lines):
            continue
        if name is not None:
            f.write("[%s]\n" % name)
        for l in lines:
            f.write(l + "\n")
PY_IWD_CONF

    if [[ ! -s "${tmp}" ]]; then
        rm -f "${tmp}"
        err "iwd: no se pudo generar main.conf canonico"
        return 1
    fi
    chmod 644 "${tmp}"
    if [[ -f "${conf}" ]] && cmp -s "${tmp}" "${conf}"; then
        rm -f "${tmp}"
        ok "iwd: main.conf ya canonico (sin cambios)"
        return 0
    fi
    mv "${tmp}" "${conf}"
    ok "iwd: main.conf canonico (un solo bloque por clave)"
    return 0
}

# _fallback_wait_ip <timeout-s> -- espera a que alguna antena WiFi tenga IP.
# Verboso: en cada ciclo imprime el estado de cada antena (ip link state,
# nmcli dev status, a que red intenta conectar y si esta activa). Best-effort:
# no aborta si vence el timeout.
_fallback_wait_ip() {
    local timeout="${1:-30}" waited=0 ip w
    info "esperando IP en alguna antena WiFi (max ${timeout}s)..."
    printf '  %-10s %-12s %-16s %s\n' "IFACE" "STATE" "CONN" "IP" >&2
    while [[ "${waited}" -lt "${timeout}" ]]; do
        for w in /sys/class/net/*/wireless; do
            [[ -d "${w}" ]] || continue
            w="${w%/wireless}"; w="${w##*/}"
            local state conn
            state="$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null \
                | awk -F: -v i="${w}" '$1==i {print $2; exit}')"
            conn="$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null \
                | awk -F: -v i="${w}" '$1==i {print $2; exit}')"
            ip="$(ip -4 -o addr show "${w}" 2>/dev/null | awk '{print $4}' | head -1)"
            printf '  %-10s %-12s %-16s %s\n' \
                "${w}" "${state:-?}" "${conn:-—}" "${ip:-—}" >&2
            if [[ -n "${ip}" ]]; then
                ok "IP asignada: ${w} ${ip}"
                return 0
            fi
        done
        sleep 3
        waited=$((waited + 3))
    done
    warn "ninguna antena obtuvo IP en ${timeout}s"

    # Diagnostico final: que perfiles existen, cuales estan activos, y
    # que dice NM sobre intentos fallidos.
    echo "" >&2
    info "perfiles NM conocidos:"
    nmcli -t -f NAME,TYPE con show 2>&1 | grep '802-11-wireless' >&2 || true
    echo "" >&2
    info "intentos fallidos (ultimos 5):"
    nmcli -f GENERAL.STATE,GENERAL.CONNECTION dev show 2>&1 | grep -E 'GENERAL\.' >&2 || true
    return 1
}

# fallback_status -- quien esta al mando.
_fallback_fix_routes() {
    local w iface="" ipx cidr prefix a b c d mask ipn netn subnet gw_fallback gw current_gw
    for w in /sys/class/net/*/wireless; do
        [ -d "${w}" ] || continue
        w="${w%/wireless}"; w="${w##*/}"
        ipx="$(ip -4 -o addr show "${w}" 2>/dev/null | awk '{print $4}' | head -1)"
        if [[ -n "${ipx}" ]]; then
            iface="${w}"
            break
        fi
    done
    if [[ -z "${iface}" ]]; then
        info "fix-routes: ninguna antena con IP, nada que hacer"
        return 0
    fi

    cidr="${ipx}"
    prefix="${cidr#*/}"
    cidr="${cidr%/*}"
    a="${cidr%%.*}"; cidr="${cidr#*.}"
    b="${cidr%%.*}"; cidr="${cidr#*.}"
    c="${cidr%%.*}"; d="${cidr##*.}"

    case "${prefix}" in
        24) subnet="${a}.${b}.${c}.0/24"; gw_fallback="${a}.${b}.${c}.1" ;;
        16) subnet="${a}.${b}.0.0/16";    gw_fallback="${a}.${b}.0.1" ;;
        8)  subnet="${a}.0.0.0/8";        gw_fallback="${a}.0.0.1" ;;
        *)
            mask=$(( (0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF ))
            ipn=$(( (a<<24)+(b<<16)+(c<<8)+d ))
            netn=$(( ipn & mask ))
            subnet="$(( (netn>>24)&255 )).$(( (netn>>16)&255 )).$(( (netn>>8)&255 )).$(( netn&255 ))/${prefix}"
            gw_fallback=""
            ;;
    esac

    if ip -4 route show | grep -qF "${subnet} dev ${iface}"; then
        info "fix-routes: subred ${subnet} ya presente en ${iface}"
    else
        if ip route add "${subnet}" dev "${iface}" 2>/dev/null; then
            ok "fix-routes: subred ${subnet} anadida en ${iface}"
        else
            warn "fix-routes: no se pudo anadir subred ${subnet} en ${iface}"
        fi
    fi

    gw="$(iwctl station "${iface}" show 2>/dev/null \
        | awk -F': ' '/Gateway/ {gsub(/ /,"",$2); print $2; exit}')"
    [[ -z "${gw}" ]] && gw="${gw_fallback}"
    [[ -n "${gw}" ]] || { info "fix-routes: sin gateway conocido, default no tocada"; return 0; }

    current_gw="$(ip -4 route show default dev "${iface}" 2>/dev/null | awk '{print $3; exit}')"
    if [[ -n "${current_gw}" ]]; then
        info "fix-routes: default ya presente via ${current_gw}"
        return 0
    fi
    if ip route add default via "${gw}" dev "${iface}" 2>/dev/null; then
        ok "fix-routes: default via ${gw} dev ${iface} anadida"
    elif ip route add default via "${gw}" dev "${iface}" onlink 2>/dev/null; then
        ok "fix-routes: default via ${gw} dev ${iface} onlink anadida"
    else
        warn "fix-routes: no se pudo anadir default via ${gw} dev ${iface}"
    fi
}

