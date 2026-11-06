#!/usr/bin/env bash
# =====================================================================
#  Instalador de XuperMH para televisores LG webOS, desde el celular
#  (Android + Termux).  Hace lo mismo que el instalador de PC:
#    1. Pide la IP y la clave (passphrase) de la app Developer Mode.
#    2. Toma la llave del TV (puerto 9991) y la abre con esa clave.
#    3. Descarga la ultima XuperMH de GitHub y COMPRUEBA SU FIRMA.
#    4. La sube al TV por SSH (puerto 9922) y la instala.
#    5. Revisa el reproductor (ffmpeg) y abre la app en el TV.
#  La llave del TV y la clave NO se guardan: se borran al terminar.
#
#  Uso:   bash instalar-termux.sh
#  Opciones avanzadas (variables de entorno):
#    XMH_IP=192.168.1.50   IP del TV (no la pregunta)
#    XMH_IPK=archivo.ipk   instalar un .ipk local (necesita su .sig al lado)
# =====================================================================
set -u

REPO="xuperaaronmh/xupermh"
APP="com.webosflux.xuptertv.fidelity"
APPDIR="/media/developer/apps/usr/palm/applications/$APP"
SVCDIR="/media/developer/apps/usr/palm/services/$APP.service"
PORT="${XMH_PORT:-9922}"
USR="${XMH_USER:-prisoner}"
KEYPORT="${XMH_KEYPORT:-9991}"

# Llave publica con la que se firman las versiones (la misma del actualizador).
PUBKEY='-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4mZ8pS5xhycJbzL156Qz
ab5KUrjlWWXJmX18BzR85+sgAHvvjznO48/ENc8skTJD50J1nXzJjk0q0h80MN0f
tp8nspFVOXaf14V3QnHkCTgERSht5y+VTqio9r9hLaXBYLrD1YNJmxdyvhETf2ta
vqihDqsnPB1k3ooYyL63N/xV/2ZZxFiXYmh/EVy8yFpB+UG1J/YZnMXPW23Q2Xin
hEe8SLBRaEb0FQOWykOFyewxfu/OVFPoQFnrTv7P4L3ZYUEaArKLkeKjXP43emFj
XqtbOtfMdqsSdR1jFcI0vhiQ+agYi1/1yDvgb6dXyHyIbmttFg5KQLrKby0nQKrz
hQIDAQAB
-----END PUBLIC KEY-----'

if [ -t 1 ]; then V=$'\e[32m'; R=$'\e[31m'; A=$'\e[33m'; N=$'\e[1m'; X=$'\e[0m'; else V=; R=; A=; N=; X=; fi
paso() { printf '\n%s[%s] %s%s\n' "$N" "$1" "$2" "$X"; }
ok()   { printf '   %s✓ %s%s\n' "$V" "$1" "$X"; }
info() { printf '   %s\n' "$1"; }
falla() {
  printf '\n   %s✗ %s%s\n' "$R" "$1" "$X"
  [ $# -gt 1 ] && printf '     %s\n' "${@:2}"
  printf '\n   Haz una captura de esta pantalla y mándasela a AarónMH.\n\n'
  exit 1
}

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/xupermh.XXXXXX")" || falla "No pude crear una carpeta temporal."
limpiar() { rm -rf "$TMPD"; }
trap limpiar EXIT INT TERM

printf '\n%s  ===========================================\n' "$N"
printf '     Instalador de XuperMH para LG webOS\n'
printf '  ===========================================%s\n' "$X"
info "Antes: en el TV abre la app Developer Mode, deja"
info "\"Dev Mode Status\" y \"Key Server\" en ON."

# ------------------------------------------------------------ 1. programas
paso 1/6 "Revisando los programas del celular"
faltan=""
command -v ssh        >/dev/null 2>&1 || faltan="$faltan openssh"
command -v ssh-keygen >/dev/null 2>&1 || faltan="$faltan openssh"
command -v openssl    >/dev/null 2>&1 || faltan="$faltan openssl"
command -v curl       >/dev/null 2>&1 || faltan="$faltan curl"
if [ -n "$faltan" ]; then
  if command -v pkg >/dev/null 2>&1; then
    info "Instalando:$faltan (solo la primera vez)"
    pkg install -y $faltan >/dev/null 2>&1 || pkg install -y $faltan
  fi
  for c in ssh ssh-keygen openssl curl; do
    command -v "$c" >/dev/null 2>&1 || falla "Falta el programa \"$c\"." "En Termux escribe: pkg install -y openssh openssl curl"
  done
fi
ok "Todo listo"

# ------------------------------------------------------------ 2. TV
paso 2/6 "Buscando el televisor"
IP="${XMH_IP:-}"
while [ -z "$IP" ]; do
  printf '   Escribe la IP que muestra Developer Mode (ej. 192.168.1.50): '
  read -r IP
  IP="$(printf '%s' "$IP" | tr -d ' ')"
done
probar() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
probar "$IP" "$PORT" || falla "El TV $IP no responde en el puerto $PORT." \
  "- ¿El TV está encendido y en el mismo Wi-Fi que el celular?" \
  "- ¿La IP es la que muestra la app Developer Mode?" \
  "- ¿\"Dev Mode Status\" está en ON?"
ok "TV encontrado en $IP"

# ------------------------------------------------------------ 3. llave
paso 3/6 "Abriendo la llave del televisor"
KEY="$TMPD/webos_rsa"
if [ -n "${XMH_KEY:-}" ]; then
  cp "$XMH_KEY" "$KEY" || falla "No pude leer la llave $XMH_KEY"
  chmod 600 "$KEY"
else
  probar "$IP" "$KEYPORT" || falla "El TV no comparte su llave (puerto $KEYPORT)." \
    "En la app Developer Mode activa \"Key Server\" y vuelve a intentar."
  curl -fsS --max-time 15 "http://$IP:$KEYPORT/webos_rsa" -o "$KEY" || falla "No pude descargar la llave del TV."
  chmod 600 "$KEY"
  intentos=0
  while :; do
    PASS="${XMH_PASS:-}"
    while [ -z "$PASS" ]; do
      printf '   Escribe la clave (Passphrase) de 6 letras que muestra el TV: '
      read -r PASS
      PASS="$(printf '%s' "$PASS" | tr -d ' ')"
    done
    if ssh-keygen -p -P "$PASS" -N "" -m PEM -f "$KEY" >/dev/null 2>&1; then break; fi
    intentos=$((intentos + 1))
    unset XMH_PASS
    [ $intentos -ge 3 ] && falla "La clave no es correcta." "Revísala en la app Developer Mode (mayúsculas y minúsculas cuentan)."
    printf '   %sLa clave no abre la llave. Revísala e inténtalo otra vez.%s\n' "$A" "$X"
  done
  PASS=""
fi
ok "Llave lista (solo se usa durante esta instalación)"

# Opciones de SSH.  Los TV LG viejos usan un servidor SSH antiguo que
#  - solo firma con ssh-rsa (SHA-1), y
#  - corta la conexion si el celular le ofrece listas de algoritmos muy
#    largas (el OpenSSH 10 de Termux ofrece mas de 20).
# Por eso se mandan listas CORTAS y exactas, que sirven a TV viejos y nuevos.
SSHO=(-i "$KEY" -p "$PORT" -o IdentitiesOnly=yes -o BatchMode=yes
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
      -o ConnectTimeout=15 -o ServerAliveInterval=15
      -o HostKeyAlgorithms=ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-256,rsa-sha2-512,ssh-rsa
      -o KexAlgorithms=curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,diffie-hellman-group14-sha256,diffie-hellman-group14-sha1
      -o Ciphers=aes128-ctr,aes256-ctr,aes128-gcm@openssh.com,chacha20-poly1305@openssh.com
      -o MACs=hmac-sha2-256,hmac-sha2-512,hmac-sha1)
tv() { ssh "${SSHO[@]}" "$USR@$IP" "$@"; }

# Firma de la llave: primero ssh-rsa (TV viejos); si no entra, rsa-sha2 (TV nuevos).
base=("${SSHO[@]}"); conectado=""
for alg in ssh-rsa rsa-sha2-256,rsa-sha2-512 ""; do
  SSHO=("${base[@]}"); [ -n "$alg" ] && SSHO+=(-o "PubkeyAcceptedAlgorithms=$alg")
  if tv 'echo ok' >/dev/null 2>&1; then conectado=1; break; fi
done
[ -n "$conectado" ] || falla "El TV no aceptó la conexión." \
  "Cierra y abre la app Developer Mode en el TV y vuelve a intentar."
ok "Conectado al TV"

# ------------------------------------------------------------ 4. descarga
paso 4/6 "Descargando XuperMH"
IPK="$TMPD/xupermh.ipk"; SIG="$TMPD/xupermh.ipk.sig"
if [ -n "${XMH_IPK:-}" ]; then
  cp "$XMH_IPK" "$IPK" && cp "$XMH_IPK.sig" "$SIG" || falla "Necesito $XMH_IPK y $XMH_IPK.sig"
  VER="$(basename "$XMH_IPK" | sed -n 's/^XuperMH-v\([0-9.]*[0-9]\)\.ipk$/\1/p')"
else
  JSON="$(curl -fsSL --max-time 20 "https://api.github.com/repos/$REPO/releases/latest")" || \
    falla "No pude consultar GitHub." "¿El celular tiene internet?"
  URL="$(printf '%s' "$JSON" | grep -o '"browser_download_url": *"[^"]*/XuperMH-v[0-9.]*\.ipk"' | head -n1 | sed 's/.*"\(https[^"]*\)"$/\1/')"
  [ -n "$URL" ] || falla "No encontré el archivo de XuperMH en GitHub."
  VER="$(printf '%s' "$URL" | sed -n 's/.*XuperMH-v\([0-9.]*[0-9]\)\.ipk$/\1/p')"
  info "Versión $VER (unos 22 MB)"
  curl -fL --progress-bar --max-time 600 "$URL" -o "$IPK" || falla "Se cortó la descarga. Vuelve a intentar."
  curl -fsSL --max-time 30 "$URL.sig" -o "$SIG" || falla "No pude descargar la firma (.sig)."
fi
[ -n "$VER" ] || falla "No pude saber la versión del archivo."
printf '%s\n' "$PUBKEY" > "$TMPD/pub.pem"
base64 -d "$SIG" > "$TMPD/sig.bin" 2>/dev/null || falla "La firma (.sig) está dañada."
openssl dgst -sha256 -verify "$TMPD/pub.pem" -signature "$TMPD/sig.bin" "$IPK" >/dev/null 2>&1 || \
  falla "La FIRMA NO COINCIDE: el archivo no es el original de AarónMH." "Por seguridad no se instala."
ok "XuperMH v$VER descargada y firma comprobada"

# ------------------------------------------------------------ 5. subir
paso 5/6 "Subiendo al televisor"
DIR="$(tv 'for d in /media/developer/temp /tmp; do mkdir -p "$d" 2>/dev/null; if ( : > "$d/.xmh" ) 2>/dev/null; then rm -f "$d/.xmh"; echo "$d"; break; fi; done')"
[ -n "$DIR" ] || falla "No encontré una carpeta donde escribir en el TV."
tv "cat > '$DIR/xupermh.ipk'" < "$IPK" || falla "Se cortó la copia al TV. Vuelve a intentar."
REM="$(tv "wc -c < '$DIR/xupermh.ipk'" | tr -d ' \r')"
LOC="$(wc -c < "$IPK" | tr -d ' ')"
[ "$REM" = "$LOC" ] || falla "La copia llegó incompleta ($REM de $LOC bytes). Vuelve a intentar."
ok "Copiado al TV"

# ------------------------------------------------------------ 6. instalar
paso 6/6 "Instalando en el televisor"
info "No cierres Termux. Tarda entre 30 segundos y 2 minutos."
tv 'sh -s' <<EOF
APP="$APPDIR"; SVC="$SVCDIR"; EXPECT="$VER"; D="$DIR"
printf '{"id":"$APP","ipkUrl":"%s/xupermh.ipk","subscribe":true}' "\$D" > "\$D/xmh-install.json"
luna-send-pub -i -f luna://com.webos.appInstallService/dev/install "\$(cat \$D/xmh-install.json)" > "\$D/xmh-install.log" 2>&1 &
PID=\$!
i=0; V=""
while [ \$i -lt 75 ]; do
  V=\$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "\$APP/appinfo.json" 2>/dev/null | head -n 1)
  [ "\$V" = "\$EXPECT" ] && break
  [ \$((i % 5)) -eq 0 ] && printf "   ."
  sleep 2; i=\$((i + 1))
done
echo ""
kill \$PID 2>/dev/null
rm -f "\$D/xupermh.ipk"
if [ "\$V" != "\$EXPECT" ]; then
  if grep -q '"downgrade"[[:space:]]*:[[:space:]]*true' "\$D/xmh-install.log" 2>/dev/null; then
    echo "   El TV tiene una versión más nueva que esta; desinstálala primero."
  fi
  echo "   El TV no confirmó la instalación (encontrada: \${V:-ninguna})."
  tail -n 8 "\$D/xmh-install.log" 2>/dev/null | sed 's/^/     /'
  exit 3
fi
P=\$(ls -l "\$SVC/ffmpeg" 2>/dev/null | cut -c1-10)
case "\$P" in *x*) : ;; *) chmod 755 "\$SVC/ffmpeg" 2>/dev/null ;; esac
P=\$(ls -l "\$SVC/ffmpeg" 2>/dev/null | cut -c1-10)
echo "   Reproductor (ffmpeg): \${P:-no encontrado}"
luna-send-pub -n 1 -f luna://com.webos.applicationManager/launch '{"id":"$APP"}' > /dev/null 2>&1
exit 0
EOF
rc=$?
[ $rc -eq 0 ] || falla "La instalación no terminó (código $rc)."
ok "XuperMH v$VER instalada"

printf '\n%s  ¡Listo! XuperMH se está abriendo en el TV.%s\n' "$V$N" "$X"
info "Desde ahora se actualiza sola. Recuerda: el Modo Desarrollador"
info "dura 50 horas; entra a la app Developer Mode y pulsa EXTEND"
info "de vez en cuando para que no se borre."
printf '\n'
