# nmcli / NetworkManager -- manual de bolsillo

Cuando `wifi ...` no alcance, este es el repertorio minimo de nmcli
para gestionar WiFi a mano. Ejemplos con nombres de ejemplo:
antena `wlan0`, red `MiCasa`, perfil `wifi-wlan0-MiCasa`.

Regla general: leer sin root; para tocar la red, `sudo`.

## 1. Inventario (siempre el primer paso)

    nmcli dev status                # devices y su estado
    nmcli dev wifi list             # redes visibles (dispara escaneo)
    nmcli -f NAME,TYPE con show     # todos los perfiles
    nmcli -t -f NAME,DEVICE con show --active   # perfiles activos

Columnas de `dev status`: DEVICE, TYPE, STATE, CONNECTION.
STATE puede ser: connected, disconnected, unavailable, unmanaged.

## 2. Escanear

    nmcli dev wifi list                       # tabla completa
    nmcli dev wifi list ifname wlan0          # solo una antena
    nmcli dev wifi list --rescan yes          # forzar rescan ahora
    nmcli -t -f SSID dev wifi list            # solo SSID, plano

`--rescan yes` requiere root (polkit). Sin el, nmcli usa el cache.

## 3. Conectar

### Crear perfil nuevo y conectar

    sudo nmcli con add type wifi \
        con-name wifi-wlan0-MiCasa \
        ifname wlan0 ssid MiCasa \
        -- wifi-sec.key-mgmt wpa-psk wifi-sec.psk 'MiClave123'
    sudo nmcli con up wifi-wlan0-MiCasa

### Conectar a perfil existente

    sudo nmcli con up wifi-wlan0-MiCasa

### Conectar sin perfil guardado (test rapido)

    sudo nmcli dev wifi connect MiCasa password 'MiClave123' ifname wlan0

### Red abierta (sin PSK)

    sudo nmcli con add type wifi con-name wifi-wlan0-Libre \
        ifname wlan0 ssid Libre
    sudo nmcli con up wifi-wlan0-Libre

## 4. Cambiar de red

    sudo nmcli con down wifi-wlan0-MiCasa
    sudo nmcli con up   wifi-wlan0-OtraRed

Para prioridad automatica: `con up` de la nueva primero, despues
`con down` de la vieja.

## 5. Cambiar la PSK

    sudo nmcli con mod wifi-wlan0-MiCasa wifi-sec.psk 'NuevaClave'
    sudo nmcli con up  wifi-wlan0-MiCasa   # reconecta con la nueva

Ver la PSK guardada:

    sudo nmcli -s -g wifi-sec.psk con show wifi-wlan0-MiCasa

`-s` (--show-secrets) la revela; sin el, sale vacia.

## 6. Autoconectar y prioridad

    # autoconnect on/off
    sudo nmcli con mod wifi-wlan0-MiCasa connection.autoconnect yes
    sudo nmcli con mod wifi-wlan0-MiCasa connection.autoconnect no

    # prioridad (mayor = preferida)
    sudo nmcli con mod wifi-wlan0-MiCasa connection.autoconnect-priority 100
    sudo nmcli con mod wifi-wlan0-OtraRed connection.autoconnect-priority 50

Cuando dos perfiles pueden conectar a la misma antena, NM prefiere el
de prioridad mas alta. Empate: el activado mas recientemente.

## 7. Eliminar perfiles

    sudo nmcli con delete wifi-wlan0-MiCasa    # uno
    sudo nmcli con show --active               # ver el activo antes

Perfiles huerfanos (apuntan a iface inexistente):

    nmcli -f NAME,DEVICE con show   # DEVICE vacio = huerfano probable
    sudo nmcli con delete <nombre>

## 8. MAC clonada (por perfil)

    sudo nmcli con mod wifi-wlan0-MiCasa 802-11-wireless.cloned-mac-address random
    sudo nmcli con mod wifi-wlan0-MiCasa 802-11-wireless.cloned-mac-address stable
    sudo nmcli con mod wifi-wlan0-MiCasa 802-11-wireless.cloned-mac-address permanent

Valores: MAC literal (aa:bb:cc:dd:ee:ff), `random`, `stable`, `permanent`.

## 9. Gestion del servicio

    systemctl status NetworkManager
    systemctl is-active NetworkManager
    sudo systemctl restart NetworkManager       # recarga todo
    sudo systemctl stop NetworkManager          # solo si vas a otro backend

Cuando esta enmascarado (`masked`), un `systemctl start` no alcanza:

    sudo systemctl unmask NetworkManager
    sudo systemctl enable NetworkManager
    sudo systemctl start  NetworkManager

## 10. Diagnostico

    nmcli general status                     # resumen NM
    nmcli dev show wlan0                     # detalle de la antena
    nmcli con show wifi-wlan0-MiCasa         # detalle del perfil
    nmcli -f GENERAL.STATE dev show          # activaciones en curso
    journalctl -u NetworkManager -n 50       # log (requiere sudo)

Errores comunes y su significado:

    Error: NetworkManager is not running.      NM parado o enmascarado.
    Error: Device 'wlan0' not found.           Antena no presente en el kernel.
    Error: Connection activation failed: ...   Ver journalctl para la causa.
    no secrets: No agents were available.      PSK no persistida; recrear el perfil.

## 11. Casos rapidos

### Forzar reconexion completa

    sudo nmcli con down wifi-wlan0-MiCasa
    sudo nmcli con up   wifi-wlan0-MiCasa

### Pasar de un perfil a otro con seguridad

    sudo nmcli con up wifi-wlan0-NuevaRed
    sleep 3
    ip -4 -o addr show wlan0        # confirmar IP
    sudo nmcli con down wifi-wlan0-Vieja

### Perfil roto, recrear desde cero

    sudo nmcli con delete wifi-wlan0-MiCasa
    sudo nmcli con add type wifi con-name wifi-wlan0-MiCasa \
        ifname wlan0 ssid MiCasa -- wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk 'MiClave123'
    sudo nmcli con up wifi-wlan0-MiCasa

### Ver que red esta activa en cada antena

    nmcli -t -f DEVICE,STATE,CONNECTION dev status

## 12. Reglas que no se rompen

- `nmcli con delete` es irreversible: el perfil y su PSK desaparecen.
- Un `con mod` no aplica hasta un `con up` (o reinicio de NM).
- El SSID va como texto (no se escapa): comillas dobles si contiene
  espacios, comillas simples si contiene `$` o backticks.
- `nmcli dev wifi list` no bloquea; `--rescan yes` si tarda.
- `journalctl -u NetworkManager` es la fuente de verdad cuando algo falla.
