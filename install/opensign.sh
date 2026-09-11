#!/usr/bin/env bash
#
# OpenSign Proxmox LXC Installer — Community-Scripts-Stil (Single-File Host-Script)
#
# App:     OpenSign — freie Open-Source DocuSign-Alternative (Dokumente signieren)
# Stack:   Node.js (Parse-Server Backend :8080) + React Frontend (:3000) + MongoDB + Caddy (:3001)
# Repo:    https://github.com/OpenSignLabs/OpenSign (Images: opensign/opensign:main, opensign/opensignserver:main)
# Lizenz:  MIT (dieses Script) — OpenSign selbst: AGPL-3.0
# Quelle:  https://github.com/OpenSignLabs/OpenSign · https://docs.opensignlabs.com/docs/self-host/docker/run-locally/
#
# Einzeiler (nach Upload in DEIN Repo, z.B. USER/opensign-proxmox, Pfad install/opensign.sh):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/opensign-proxmox/main/install/opensign.sh)"
# Debug-Modus bei Fehlern:
#   bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/USER/opensign-proxmox/main/install/opensign.sh)"
#
# Was das Script tut (idempotent, mehrfach lauffähig):
#   1. Prüft Proxmox-Host (root, pveversion, pct, pveam)
#   2. Ermittelt freie CTID (oder nutzt CTID aus ENV), lädt Debian-12 Template bei Bedarf
#   3. Erstellt LXC (Standard 2 vCPU / 4 GB RAM / 15 GB Disk, onboot=1, nesting für Docker)
#   4. Installiert Docker + Compose-Plugin im Container (nur wenn fehlend)
#   5. Legt /opt/opensign/{docker-compose.yml,.env.prod,Caddyfile} an (LAN-HTTP-Modus, USE_LOCAL=true)
#   6. Legt systemd-Unit opensign.service an (enable + Restart=always, After docker+network-online)
#   7. Startet Stack (docker compose pull + up -d), verifiziert Service + HTTP, gibt URL aus
#
set -euo pipefail

# ============================================================================
# KONFIGURATION — alles hier oben anpassbar (ENV überschreibt Default)
# ============================================================================
APP="${APP:-opensign}"
CTID="${CTID:-}"                          # leer = nächste freie ID via pvesh
# LXC-Name. ABSICHTLICH NICHT "HOSTNAME": $HOSTNAME setzt die Shell automatisch
# auf den Proxmox-Hostnamen (z.B. "Prox") — ein Default würde nie greifen und jeder
# Container hieße wie der Host. Daher CT_HOSTNAME (Default: opensign).
CT_HOSTNAME="${CT_HOSTNAME:-}"
CPU="${CPU:-2}"
RAM="${RAM:-4096}"                        # MiB (OpenSign + Mongo brauchen min. ~2 GB, empfohlen 4 GB)
DISK="${DISK:-15}"                        # GB (min. 10, empfohlen 15 inkl. Dokumente)
STORAGE="${STORAGE:-local-lvm}"           # Rootfs-Storage für den Container
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # Storage für Container-Templates
TEMPLATE="${TEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_MODE="${IP_MODE:-dhcp}"                # "dhcp" oder statisch "192.168.1.50/24"
GATEWAY="${GATEWAY:-}"                    # nur bei statischer IP nötig, z.B. 192.168.1.1
DNS="${DNS:-1.1.1.1}"
UNPRIVILEGED="${UNPRIVILEGED:-0}"         # 0=privilegiert (empfohlen für Docker), 1=unprivilegiert geht auch mit nesting+keyctl
FEATURES="${FEATURES:-nesting=1,keyctl=1}"
ONBOOT="${ONBOOT:-1}"

# Admin-Erstzugang (Login im UI = E-Mail; wird per usersignup-Cloud-Function
# angelegt inkl. Tenant + contracts_Admin-Rolle und am Ende ausgegeben)
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@opensign.local}"
ADMIN_PASS="${ADMIN_PASS:-admin}"                    # nach 1. Login ändern! (kein " oder \ verwenden)
ADMIN_NAME="${ADMIN_NAME:-Administrator}"
SEED_ADMIN="${SEED_ADMIN:-1}"                        # 0 = keinen Admin anlegen (nur Hinweis ausgeben)

UI_PORT="${UI_PORT:-3001}"                # Caddy — das ist die Web-UI URL
CLIENT_PORT="${CLIENT_PORT:-3000}"        # React Frontend (Debug/Direktzugriff)
SERVER_PORT="${SERVER_PORT:-8080}"        # Parse-API (Debug/Direktzugriff)
MONGO_PORT="${MONGO_PORT:-27018}"         # Host-Mapping für Mongo (27017 bleibt intern!)

INSTALL_DIR="${INSTALL_DIR:-/opt/opensign}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
SKIP_CPU_CHECK="${SKIP_CPU_CHECK:-0}"            # 1 = AVX-Prüfung überspringen (nur wenn du weißt, was du tust)
MONGO_IMAGE="${MONGO_IMAGE:-mongo:7.0}"   # gepinnt (upstream nutzt :latest — nicht reproduzierbar)
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"
SERVER_IMAGE="${SERVER_IMAGE:-opensign/opensignserver:main}"  # upstream publiziert nur :main/:staging
CLIENT_IMAGE="${CLIENT_IMAGE:-opensign/opensign:main}"
# ============================================================================

# Farben / Logging im Community-Scripts-Stil
if [[ -t 1 ]]; then
  C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RED='\033[31m'; C_BLUE='\033[34m'; C_RESET='\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_RESET=''
fi
log_info() { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
log_ok()   { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*" >&2; }
log_err()  { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# --- Vollständige Fehlerkette (niemals nur die letzte Zeile) ---
err_trap() {
  local ec=$?
  local cmd="${BASH_COMMAND:-unbekannt}"
  log_err "═════════ FEHLERKETTE ═════════"
  log_err "Exit-Code   : ${ec}"
  log_err "Fehlgeschlagen: ${cmd}"
  log_err "Script      : ${BASH_SOURCE[1]:-main} Zeile ${BASH_LINENO[0]:-?}"
  log_err "Stacktrace  :"
  local i=0
  while caller $i 2>/dev/null; do i=$((i+1)); done >&2
  log_err "───────────────────────────────"
  log_err "Relevante Logs (falls vorhanden):"
  log_err "  Host: pvesh get /nodes/\$(hostname)/tasks --limit 5  |  pct logs <CTID> 2>/dev/null"
  log_err "  LXC : pct exec <CTID] -- journalctl -u opensign --no-pager -n 50"
  log_err "        pct exec <CTID> -- docker logs OpenSignServer-container --tail 50"
  log_err "        pct exec <CTID> -- docker logs OpenSign-container --tail 50"
  log_err "Retry mit Trace:"
  log_err "  bash -x -c \"\$(wget -qLO - <EINZEILER-URL>)\""
  log_err "═══════════════════════════════"
}
trap err_trap ERR

die() { log_err "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Befehl '$1' fehlt. Läuft das Script auf dem Proxmox-Host als root?"; }

pct_exec() { pct exec "$CTID" -- bash -c "$*"; }

get_next_id() {
  pvesh get /cluster/nextid 2>/dev/null | tr -d '[:space:]"' || echo "200"
}

container_exists() { pct status "$1" >/dev/null 2>&1; }

container_ip() {
  # Versucht IP via pct exec zu ermitteln (eth0), Fallback: pct config
  pct exec "$CTID" -- bash -c "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null \
    || pct config "$CTID" | grep -oP '(?<=ip=)[0-9.]+' | head -1 || true
}

ensure_template() {
  if pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${TEMPLATE%%_*}"; then
    log_ok "Template vorhanden (${TEMPLATE_STORAGE})."
    return 0
  fi
  log_info "Aktualisiere Template-Liste (${TEMPLATE_STORAGE}) …"
  pveam update
  log_info "Lade Template ${TEMPLATE} … (kann einige Minuten dauern)"
  # Vollständige Ausgabe behalten — bei Fehler greift err_trap mit Kette
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}" \
    || { log_warn "Exaktes Template nicht gefunden, suche debian-12 Fallback …";
         local fb; fb=$(pveam available --section system 2>/dev/null | grep -oP 'debian-12-standard_[^\s]+\.tar\.zst' | head -1);
         [[ -n "${fb:-}" ]] || die "Kein debian-12 Template verfügbar. pveam-Ausgabe prüfen.";
         TEMPLATE="$fb"; log_info "Fallback-Template: $TEMPLATE";
         pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"; }
  log_ok "Template bereit: $TEMPLATE"
}

create_container() {
  local ip_param nameserver=""
  if [[ "$IP_MODE" == "dhcp" ]]; then ip_param="ip=dhcp";
  else ip_param="ip=${IP_MODE}"; [[ -n "$GATEWAY" ]] && ip_param="${ip_param},gw=${GATEWAY}"; fi
  [[ -n "$DNS" ]] && nameserver="--nameserver $DNS"

  log_info "Erstelle LXC ${CTID} (${CT_HOSTNAME}: ${CPU} vCPU / ${RAM} MB / ${DISK} GB, onboot=${ONBOOT}) …"
  # shellcheck disable=SC2086
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CPU" --memory "$RAM" --swap 512 \
    --rootfs "${STORAGE}:${DISK}" \
    --ostype debian \
    --arch amd64 \
    --unprivileged "$UNPRIVILEGED" \
    --features "$FEATURES" \
    --onboot "$ONBOOT" \
    --start 0 \
    --net0 "name=eth0,bridge=${BRIDGE},${ip_param}" \
    $nameserver \
    --timezone "$TIMEZONE"
  log_ok "Container ${CTID} erstellt."
}

start_container() {
  if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
    log_info "Starte Container ${CTID} …"
    pct start "$CTID"
  fi
  log_info "Warte auf Netzwerk im Container (max. 90s) …"
  for i in $(seq 1 45); do
    local ip; ip="$(container_ip)"
    if [[ -n "${ip:-}" ]]; then log_ok "Container-IP: $ip"; return 0; fi
    sleep 2
  done
  die "Container ${CTID} hat keine IP bekommen. Prüfe Bridge/DHCP: pct config ${CTID}"
}

# DNS-Gate: Ohne funktionierende Namensauflösung hängt/scheitert alles danach
# (apt, get.docker.com, Registry-Pulls). DHCP überschreibt /etc/resolv.conf gern
# mit Router-DNS — darum prüfen, bei Bedarf feste Server setzen + per dhclient-Hook
# persistent machen, sonst mit Routing-vs-DNS-Diagnose abbrechen statt hängen.
ensure_container_dns() {
  log_info "Prüfe DNS im Container (deb.debian.org, raw.githubusercontent.com) …"
  if pct exec "$CTID" -- bash -c "getent hosts deb.debian.org >/dev/null && getent hosts raw.githubusercontent.com >/dev/null"; then
    log_ok "DNS im Container funktioniert."
    return 0
  fi
  log_warn "DNS-Auflösung schlägt fehl — setze feste DNS-Server (${DNS}, 1.1.1.1, 8.8.8.8) …"
  pct exec "$CTID" -- bash -c "printf 'nameserver ${DNS}\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' | awk '!seen[\$0]++' > /etc/resolv.conf && mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf 'make_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/keep-dns && cat /etc/resolv.conf"
  sleep 2
  if pct exec "$CTID" -- bash -c "getent hosts deb.debian.org >/dev/null && getent hosts raw.githubusercontent.com >/dev/null"; then
    log_ok "DNS repariert (persistent via dhclient-Hook)."
    return 0
  fi
  if pct exec "$CTID" -- bash -c "ping -c1 -W3 1.1.1.1 >/dev/null 2>&1"; then
    die "DNS im Container tot, Routing OK. Prüfe: Proxmox-Firewall (pve-firewall status + Regeln für Port 53 auf Datacenter/Node/CT), Router-DNS/Kindersicherung, 'pct config ${CTID} | grep -E \"nameserver|net0\"'."
  else
    die "Kein Netzwerk im Container (Ping auf 1.1.1.1 scheitert). Prüfe: Bridge (${BRIDGE}), Gateway (statisch: '${GATEWAY:-–}' / DHCP-Lease am Router), Proxmox-Firewall, 'pct exec ${CTID} -- ip route'."
  fi
}

# ============================================================================
# Setup INNERHALB des Containers (via pct exec, idempotent)
# ============================================================================
setup_inside() {
  log_info "Installiere OpenSign in LXC ${CTID} (idempotent) …"
  pct exec "$CTID" -- bash -s -- "$UI_PORT" "$CLIENT_PORT" "$SERVER_PORT" "$MONGO_PORT" "$INSTALL_DIR" "$MONGO_IMAGE" "$CADDY_IMAGE" "$SERVER_IMAGE" "$CLIENT_IMAGE" "$ADMIN_EMAIL" "$ADMIN_PASS" "$ADMIN_NAME" "$SEED_ADMIN" "$TIMEZONE" <<'INNER_EOF'
set -euo pipefail
UI_PORT="$1"; CLIENT_PORT="$2"; SERVER_PORT="$3"; MONGO_PORT="$4"; INSTALL_DIR="$5"
MONGO_IMAGE="$6"; CADDY_IMAGE="$7"; SERVER_IMAGE="$8"; CLIENT_IMAGE="$9"
ADMIN_EMAIL="${10}"; ADMIN_PASS="${11}"; ADMIN_NAME="${12}"; SEED_ADMIN="${13:-1}"; TZ_INNER="${14:-Europe/Berlin}"

echo "[INFO]  OS-Update + Basis-Pakete …"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=2"
apt-get $APT_OPTS update
apt-get $APT_OPTS install -y --no-install-recommends ca-certificates curl wget gnupg openssl iproute2 systemd-sysv 2>&1 | tail -5

echo "[INFO]  Docker prüfen/installieren (idempotent) …"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh 2>&1 | tail -10
  rm -f /tmp/get-docker.sh
else
  echo "[OK]    Docker bereits vorhanden: $(docker --version)"
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "[INFO]  Installiere docker-compose-plugin …"
  apt-get install -y --no-install-recommends docker-compose-plugin 2>&1 | tail -3
fi
systemctl enable --now docker 2>&1 | tail -2 || service docker start || true
docker --version; docker compose version

LXC_IP="$(hostname -I | awk '{print $1}')"
[[ -n "${LXC_IP:-}" ]] || { echo "[ERROR] Keine Container-IP gefunden"; ip addr; exit 1; }
HOST_URL="http://${LXC_IP}:${UI_PORT}"
echo "[INFO]  HOST_URL=${HOST_URL}"
mkdir -p "${INSTALL_DIR}"

# MASTER_KEY idempotent: wiederverwenden falls vorhanden, sonst neu
if [[ -f "${INSTALL_DIR}/.env.prod" ]] && grep -q '^MASTER_KEY=' "${INSTALL_DIR}/.env.prod"; then
  MASTER_KEY="$(grep '^MASTER_KEY=' "${INSTALL_DIR}/.env.prod" | cut -d= -f2 | tr -d '\r' | head -1)"
  [[ -n "${MASTER_KEY:-}" ]] || MASTER_KEY="$(openssl rand -hex 6)"
else
  MASTER_KEY="$(openssl rand -hex 6)"
fi
echo "[INFO]  Schreibe ${INSTALL_DIR}/.env.prod …"
cat > "${INSTALL_DIR}/.env.prod" <<EOF
# OpenSign LAN-Installation (generiert vom Proxmox-Installer, idempotent — MASTER_KEY bleibt stabil)
PUBLIC_URL=${HOST_URL}
REACT_APP_APPID=opensign
REACT_APP_SERVERURL=${HOST_URL}/api/app
GENERATE_SOURCEMAP=false
appName=open_sign_server
MASTER_KEY=${MASTER_KEY}
MONGODB_URI=mongodb://mongo-container:27017/OpenSignDB
PARSE_MOUNT=/app
SERVER_URL=${HOST_URL}/api/app
USE_LOCAL=true
SMTP_ENABLE=false
SMTP_HOST=smtp.yourhost.com
SMTP_PORT=587
SMTP_USER_EMAIL=mailer@yourdomain.com
SMTP_PASS=changeme
MAILGUN_API_KEY=
MAILGUN_DOMAIN=
MAILGUN_SENDER=
DO_SPACE=
DO_ENDPOINT=
DO_ACCESS_KEY_ID=
DO_SECRET_ACCESS_KEY=
DO_REGION=
APP_ID=opensign
EOF

echo "[INFO]  Schreibe ${INSTALL_DIR}/Caddyfile (HTTP, kein TLS für LAN-IP) …"
cat > "${INSTALL_DIR}/Caddyfile" <<EOF
# LAN-Modus: reines HTTP auf :${UI_PORT} (kein ACME/TLS — IPs bekommen kein LE-Zertifikat)
# WICHTIG: server/client-Ports sind die FIXEN Container-internen Ports der Images
# (8080/3000) — nicht die Host-Mappings weiter unten verwechseln.
:${UI_PORT} {
  handle_path /api/* {
    reverse_proxy server:8080
  }
  handle {
    reverse_proxy client:3000
  }
}
EOF

echo "[INFO]  Schreibe ${INSTALL_DIR}/docker-compose.yml …"
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
# OpenSign LAN-Stack (Proxmox-Installer). Upstream: https://github.com/OpenSignLabs/OpenSign/blob/main/docker-compose.yml
services:
  server:
    image: ${SERVER_IMAGE}
    container_name: OpenSignServer-container
    restart: unless-stopped
    depends_on: [mongo]
    env_file: .env.prod
    environment:
      - NODE_ENV=production
      - SERVER_URL=${HOST_URL}/api/app
      - PUBLIC_URL=${HOST_URL}
    volumes: [opensign-files:/usr/src/app/files]
    networks: [app-network]
  mongo:
    image: ${MONGO_IMAGE}
    container_name: mongo-container
    restart: unless-stopped
    volumes: [data-volume:/data/db]
    networks: [app-network]
  client:
    image: ${CLIENT_IMAGE}
    container_name: OpenSign-container
    restart: unless-stopped
    depends_on: [server]
    env_file: .env.prod
    networks: [app-network]
  caddy:
    image: ${CADDY_IMAGE}
    container_name: caddy-container
    restart: unless-stopped
    depends_on: [server, client]
    ports:
      - "${UI_PORT}:${UI_PORT}"
      - "${CLIENT_PORT}:3000"
      - "${SERVER_PORT}:8080"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks: [app-network]
networks:
  app-network: {driver: bridge}
volumes:
  data-volume:
  caddy_data:
  caddy_config:
  opensign-files:
EOF

echo "[INFO]  Lege systemd-Unit opensign.service an (reboot-sicher) …"
cat > /etc/systemd/system/opensign.service <<EOF
[Unit]
Description=OpenSign Docker Stack (Proxmox LXC Installer)
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
ExecReload=/usr/bin/docker compose pull
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable opensign.service
systemctl enable docker.service || true

echo "[INFO]  Starte Stack (pull + up -d) …"
cd "${INSTALL_DIR}"
docker compose pull 2>&1 | tail -20
docker compose up -d 2>&1 | tail -20

# Unit auf "active" bringen: nur "enable" reicht NICHT — ohne "start" bleibt eine
# oneshot-Unit auf inactive(dead) und die Verifikation schlägt fehl (mit
# RemainAfterExit=yes meldet is-active nach erfolgreichem start "active"/exited).
echo "[INFO]  Starte opensign.service …"
systemctl start opensign.service 2>&1 | tail -5 || {
  echo "[ERROR] systemctl start opensign.service fehlgeschlagen (Exit $?)"
  echo "--- systemctl status ---"; systemctl status opensign --no-pager || true
  echo "--- journal ---"; journalctl -u opensign --no-pager -n 50 || true
  exit 1
}

echo "[INFO]  Verifikation im Container …"
systemctl is-active --quiet docker || { echo "[ERROR] docker.service nicht aktiv"; systemctl status docker --no-pager; exit 1; }
echo "[OK]    docker.service aktiv"
if ! systemctl is-active --quiet opensign.service; then
  echo "[WARN]  opensign.service nicht aktiv — versuche restart …"
  systemctl restart opensign.service || true
  sleep 3
fi
systemctl is-active --quiet opensign.service || { echo "[ERROR] opensign.service nicht aktiv"; systemctl status opensign --no-pager; journalctl -u opensign --no-pager -n 50; exit 1; }
echo "[OK]    opensign.service aktiv"

echo "[INFO]  Warte auf Web-UI (max. 180s): ${HOST_URL} …"
ok=0
for i in $(seq 1 36); do
  if curl -fsS -m 5 "http://127.0.0.1:${UI_PORT}/" -o /dev/null 2>&1; then ok=1; break; fi
  if curl -fsS -m 5 "http://127.0.0.1:${CLIENT_PORT}/" -o /dev/null 2>&1; then echo "[INFO]  (Frontend :${CLIENT_PORT} schon da, Caddy läuft noch hoch …)"; fi
  sleep 5
done
[[ "$ok" == "1" ]] || {
  echo "[ERROR] Web-UI antwortet nicht auf 127.0.0.1:${UI_PORT}"
  echo "--- docker ps ---"; docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  echo "--- caddy logs ---"; docker logs caddy-container --tail 50 2>&1 || true
  echo "--- server logs ---"; docker logs OpenSignServer-container --tail 50 2>&1 || true
  echo "--- client logs ---"; docker logs OpenSign-container --tail 50 2>&1 || true
  exit 1
}
echo "[OK]    Web-UI antwortet auf localhost:${UI_PORT}"
docker ps --format 'table {{.Names}}\t{{.Status}}'

# --- Admin-Erstzugang anlegen (idempotent) ---------------------------------
# Gleicher Weg wie die UI-Registrierung: Cloud-Function "usersignup" (legt
# _User + partners_Tenant + contracts_Users-Eintrag an). Ein reiner DB-Insert
# würde einen User ohne Tenant/Rolle erzeugen, der sich NICHT einloggen kann.
# Danach Login-Verifikation exakt wie das UI (Cloud-Function "loginuser").
echo "[INFO]  Admin-User anlegen (${ADMIN_EMAIL}) …"
APPID="$(grep '^APP_ID=' "${INSTALL_DIR}/.env.prod" 2>/dev/null | cut -d= -f2 | tr -d '\r' | head -1)"
APPID="${APPID:-opensign}"
API="http://127.0.0.1:${SERVER_PORT}/app"
LOGIN_OK=0; LOGIN_NOTE="Seed übersprungen (SEED_ADMIN=0)"
dump_api_debug() {
  echo "--- docker ps ---"; docker ps
  echo "--- Container-Status ---"; docker inspect -f 'Name={{.Name}} RestartCount={{.RestartCount}} Status={{.State.Status}} Exit={{.State.ExitCode}}' mongo-container OpenSignServer-container OpenSign-container caddy-container 2>/dev/null || true
  echo "--- CPU-Flags (AVX?) ---"; grep -m1 -o 'avx[^ ]*' /proc/cpuinfo 2>/dev/null | sort -u || echo "KEIN AVX in /proc/cpuinfo → MongoDB 5+ kann hier NICHT laufen (Exit 132/SIGILL)"
  echo "--- server logs (tail 60) ---"; docker logs OpenSignServer-container --tail 60 2>&1 || true
  echo "--- mongo logs (tail 20) ---"; docker logs mongo-container --tail 20 2>&1 || true
}
if [[ "${SEED_ADMIN}" == "1" ]]; then
  # Phase 1: Auf die Parse-API warten — der Erststart enthält die DB-Migration und
  # dauert (je nach Disk) mehrere Minuten. Ohne Gate läuft der Seed ins Leere.
  echo "[INFO]  Warte auf Parse-API (${API}/health, max. ~5 Min: Erststart = Migration) …"
  api_ok=0; hcode="?"
  for i in $(seq 1 30); do
    hcode="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "${API}/health" 2>/dev/null)"
    hcode="${hcode: -3}"; hcode="${hcode:-000}"
    if [[ "${hcode}" == "200" ]]; then api_ok=1; break; fi
    for _c in mongo-container OpenSignServer-container; do
      rc="$(docker inspect -f '{{.RestartCount}}' "$_c" 2>/dev/null || echo ?)"
      if [[ "${rc}" =~ ^[0-9]+$ && "${rc}" -ge 3 ]]; then
        echo "[ERROR] Container ${_c} startet ständig neu (Restarts: ${rc}) — volle Kette:"
        dump_api_debug
        exit 1
      fi
    done
    if (( i % 6 == 0 )); then echo "[INFO]  … API noch nicht bereit (Versuch ${i}/30, HTTP ${hcode})"; fi
    sleep 10
  done
  if [[ "${api_ok}" != "1" ]]; then
    echo "[ERROR] Parse-API antwortet nicht (letzter HTTP-Code: ${hcode}) — volle Kette:"
    dump_api_debug
    exit 1
  fi
  echo "[OK]    Parse-API bereit."
  # Phase 2: Seed + Login-Verifikation (mit HTTP-Code statt leerer Rate-Responses)
  LOGIN_NOTE="Admin-Anlage fehlgeschlagen (Details oben im Log)"
  last_resp=""; last_code="?"
  for i in $(seq 1 12); do
    resp="$(curl -s -m 20 -w '\nHTTP:%{http_code}' -X POST "${API}/functions/usersignup" \
      -H 'Content-Type: application/json' \
      -H "X-Parse-Application-Id: ${APPID}" \
      -d "{\"userDetails\":{\"name\":\"${ADMIN_NAME}\",\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\",\"phone\":\"\",\"role\":\"contracts_Admin\",\"company\":\"Local\",\"jobTitle\":\"Administrator\",\"timezone\":\"${TZ_INNER}\"}}" 2>&1)"
    last_code="$(echo "$resp" | grep -o 'HTTP:[0-9]*$' | cut -d: -f2)"; last_code="${last_code:-?}"
    seed="$(echo "$resp" | sed '$d')"; last_resp="$seed"
    if echo "$seed" | grep -q 'sessionToken\|User sign up\|User already exist'; then
      lresp="$(curl -s -m 20 -w '\nHTTP:%{http_code}' -X POST "${API}/functions/loginuser" \
        -H 'Content-Type: application/json' \
        -H "X-Parse-Application-Id: ${APPID}" \
        -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\"}" 2>&1)"
      login="$(echo "$lresp" | sed '$d')"
      if echo "$login" | grep -q '"objectId"'; then
        LOGIN_OK=1; LOGIN_NOTE="angelegt + Login-Verifikation OK"; break
      else
        LOGIN_NOTE="User existiert, aber Login mit diesem Passwort schlägt fehl (Passwort wurde früher anders gesetzt?)"
        echo "[WARN]  ${LOGIN_NOTE}"
        echo "--- loginuser-Antwort (Debug) ---"; echo "$login" | head -c 500; echo
        break
      fi
    fi
    if (( i % 4 == 0 )); then echo "[INFO]  … Seed-Versuch ${i}/12 (HTTP ${last_code})"; fi
    sleep 8
  done
  if [[ "$LOGIN_OK" == "1" ]]; then
    echo "[OK]    Admin-User: ${ADMIN_EMAIL} (${LOGIN_NOTE})"
  else
    echo "[WARN]  ${LOGIN_NOTE} (letzter HTTP-Code: ${last_code})"
    echo "--- letzte usersignup-Antwort (Debug) ---"; echo "$last_resp" | head -c 500; echo
    dump_api_debug
  fi
fi
# Status für den Host-Teil (Banner) persistieren — Note ohne Pipe-Zeichen
echo "${LOGIN_OK}|$(echo "${LOGIN_NOTE}" | tr -d '|')" > "${INSTALL_DIR}/.seed_status"
echo "INNER_DONE HOST_URL=${HOST_URL} LXC_IP=${LXC_IP}"
INNER_EOF
  log_ok "Setup im Container abgeschlossen."
}

verify_from_host() {
  local ip; ip="$(container_ip)"
  log_info "Verifikation vom Host aus (LXC ${CT_HOSTNAME} / CT ${CTID}, IP ${ip:-?}) …"
  local cur_name; cur_name="$(pct exec "$CTID" -- hostname 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "${cur_name:-}" && "${cur_name}" != "${CT_HOSTNAME}" ]]; then
    log_warn "Hostname im Container ist '${cur_name}', erwartet '${CT_HOSTNAME}' (wird unten per Reboot erzwungen)."
  else
    log_ok "LXC-Name: ${CT_HOSTNAME} (CTID ${CTID})."
  fi
  pct_exec "systemctl is-active --quiet opensign.service && echo HOST_OK_opensign_active || (systemctl status opensign --no-pager; exit 1)"
  pct_exec "systemctl is-active --quiet docker && echo HOST_OK_docker_active || (systemctl status docker --no-pager; exit 1)"
  # HTTP-Check durch den Container (localhost im LXC)
  pct_exec "curl -fsS -m 10 http://127.0.0.1:${UI_PORT}/ -o /dev/null && echo HOST_OK_http_${UI_PORT}"
  log_ok "Alle Checks bestanden."
  local seed_status; seed_status="$(pct_exec "cat ${INSTALL_DIR}/.seed_status 2>/dev/null" || true)"
  local seed_ok="${seed_status%%|*}"; local seed_note="${seed_status#*|}"
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  OpenSign ist bereit!"
  echo "  Web-UI : http://${ip}:${UI_PORT}"
  echo "  API    : http://${ip}:${UI_PORT}/api/app  (direkt: http://${ip}:${SERVER_PORT}/app)"
  echo "  LXC    : ${CT_HOSTNAME}  (CTID ${CTID} — pct enter ${CTID} / pct exec ${CTID} -- docker ps)"
  if [[ "${SEED_ADMIN}" == "1" ]]; then
    echo "  Login  : ${ADMIN_EMAIL} / ${ADMIN_PASS}"
    if [[ "${seed_ok}" == "1" ]]; then
      echo "           (Admin, ${seed_note}; bitte nach erstem Login Passwort ändern!)"
    else
      echo "           (ACHTUNG: ${seed_note:-Status unbekannt} → ggf. einmalig im UI registrieren)"
    fi
  else
    echo "  Login  : Seed deaktiviert (SEED_ADMIN=0) → bitte einmalig im UI registrieren."
  fi
  echo "  SMTP ist deaktiviert — für E-Mail-Versand .env.prod im Container anpassen:"
  echo "    pct exec ${CTID} -- nano ${INSTALL_DIR}/.env.prod && pct exec ${CTID} -- systemctl restart opensign"
  echo "════════════════════════════════════════════════════"
}

main() {
  [[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
  need_cmd pveversion; need_cmd pct; need_cmd pveam; need_cmd pvesh; need_cmd wget
  pveversion >/dev/null || die "pveversion fehlgeschlagen — kein Proxmox-Host?"

  # CPU-Gate (fail fast, VOR Container-Erstellung): MongoDB 5+ braucht den
  # AVX-Befehlssatz und stirbt ohne ihn mit Exit 132 (SIGILL, Crash-Loop);
  # Parse Server 8 braucht MongoDB 6+ — ein älteres Mongo ist keine Option.
  # LXC sieht die Host-CPU 1:1, daher gilt der Host-Check auch für den Container.
  if [[ "${SKIP_CPU_CHECK}" != "1" ]]; then
    if ! grep -qw avx /proc/cpuinfo 2>/dev/null; then
      die "CPU ohne AVX-Befehlssatz (kein 'avx' in /proc/cpuinfo). MongoDB 5+ startet ohne AVX nicht (Exit 132/SIGILL, Endlos-Restarts), Parse Server 8 braucht MongoDB 6+. Auf dieser Hardware kann OpenSign nicht laufen — neuerer Host nötig (oder VM mit AVX-Passthrough auf AVX-Hardware). Override auf eigene Gefahr: SKIP_CPU_CHECK=1."
    fi
    log_ok "CPU-Check: AVX vorhanden."
  else
    log_warn "SKIP_CPU_CHECK=1 — AVX-Prüfung übersprungen (bei mongo-Restarts mit Exit 132: Hardware zu alt)."
  fi

  if [[ -z "${CTID:-}" ]]; then CTID="$(get_next_id)"; log_info "Keine CTID vorgegeben → nutze nächste freie ID: ${CTID}"; fi
  [[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID muss numerisch sein (bekommen: '$CTID')."

  # LXC-Name auflösen: ein exportiertes HOSTNAME stammt (fast) immer von der Shell
  # selbst (= Proxmox-Hostname) und ist NICHT als Wunschname gemeint → ignorieren.
  if [[ -z "${CT_HOSTNAME:-}" ]]; then
    [[ -n "${HOSTNAME:-}" ]] && log_warn "Umgebungsvariable HOSTNAME ('${HOSTNAME}') wird ignoriert (Shell-reserviert für den Proxmox-Host). LXC-Name per CT_HOSTNAME setzen."
    CT_HOSTNAME="opensign"
  fi
  # LXC-Name normalisieren + validieren (Proxmox/hostname: klein, max. 63 Zeichen)
  CT_HOSTNAME="$(echo "${CT_HOSTNAME}" | tr '[:upper:]' '[:lower:]')"
  [[ "$CT_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || die "CT_HOSTNAME ungültig: '${CT_HOSTNAME}' (erlaubt: Kleinbuchstaben, Ziffern, Bindestrich, max. 63 Zeichen)."

  # Admin-Credentials früh validieren (werden als JSON an die Parse-API geschickt)
  if [[ "${SEED_ADMIN:-1}" == "1" ]]; then
    [[ -n "${ADMIN_EMAIL:-}" && -n "${ADMIN_PASS:-}" ]] || die "ADMIN_EMAIL/ADMIN_PASS dürfen nicht leer sein."
    case "${ADMIN_EMAIL}${ADMIN_PASS}${ADMIN_NAME:-x}" in
      *\"*|*\\*) die "ADMIN_EMAIL/ADMIN_PASS/ADMIN_NAME dürfen keine Anführungszeichen oder Backslashes enthalten.";;
    esac
  fi

  echo ""
  echo "── ${APP}-Installer ─────────────────────────────────"
  echo "  LXC-Name : ${CT_HOSTNAME}  (CTID ${CTID})"
  echo "  Ressourcen: ${CPU} vCPU / ${RAM} MB RAM / ${DISK} GB Disk (${STORAGE})"
  echo "  Netzwerk : ${BRIDGE} / ${IP_MODE}  ·  Web-UI-Port: ${UI_PORT}"
  if [[ "${SEED_ADMIN:-1}" == "1" ]]; then echo "  Admin    : ${ADMIN_EMAIL}  (wird angelegt + am Ende ausgegeben)"; fi
  echo "─────────────────────────────────────────────────────"

  if container_exists "$CTID"; then
    log_warn "Container ${CTID} existiert bereits → idempotentes Update/Re-Run (kein Neu-Erstellen)."
  else
    ensure_template
    create_container
  fi
  start_container
  # onboot + LXC-Name sicherstellen (auch bei existierenden CTs).
  # Reihenfolge: erst Config (greift beim Boot), dann live im Container.
  # hostnamectl braucht D-Bus (im LXC oft abwesend) → "hostname" (Syscall) zuerst,
  # plus /etc/hostname + /etc/hosts als Gürtel-und-Hosenträger.
  pct set "$CTID" --onboot "$ONBOOT" 2>/dev/null || true
  pct set "$CTID" --hostname "$CT_HOSTNAME" 2>/dev/null || true
  pct config "$CTID" | grep -q "^hostname: ${CT_HOSTNAME}$" \
    || log_warn "pct-Config meldet anderen Hostnamen — prüfe: pct config ${CTID} | grep hostname"
  pct exec "$CTID" -- bash -c "echo '${CT_HOSTNAME}' > /etc/hostname; grep -q '^127.0.1.1' /etc/hosts && sed -i 's/^127.0.1.1.*/127.0.1.1\t${CT_HOSTNAME}/' /etc/hosts || echo -e '127.0.1.1\t${CT_HOSTNAME}' >> /etc/hosts; hostname '${CT_HOSTNAME}' 2>/dev/null || hostnamectl set-hostname '${CT_HOSTNAME}' 2>/dev/null || true" 2>/dev/null || true
  ensure_container_dns
  setup_inside
  verify_from_host
  ensure_hostname
  log_ok "Fertig. Web-UI: http://$(container_ip):${UI_PORT}  (Login: ${ADMIN_EMAIL} / ${ADMIN_PASS})"
}

# Hostname hart durchsetzen: Falls der live-Hostname (trotz Config + live-Setzen)
# immer noch abweicht, genau EINMAL rebooten (Config greift beim Boot garantiert)
# und danach beweisen, dass Services + Web-UI von selbst wiederkommen.
ensure_hostname() {
  local live; live="$(pct exec "$CTID" -- hostname 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "${live}" == "${CT_HOSTNAME}" ]]; then
    log_ok "Hostname final: ${live} (kein Reboot nötig)."
    return 0
  fi
  log_warn "Hostname live '${live:-?}' ≠ '${CT_HOSTNAME}' → Reboot (einmalig, Config ist gesetzt) …"
  pct reboot "$CTID"
  log_info "Warte auf Reboot (max. 120s) …"
  local i
  for i in $(seq 1 60); do
    if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" == "running" ]]; then
      live="$(pct exec "$CTID" -- hostname 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ "${live}" == "${CT_HOSTNAME}" && -n "$(container_ip)" ]]; then break; fi
    fi
    sleep 2
  done
  live="$(pct exec "$CTID" -- hostname 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "${live}" == "${CT_HOSTNAME}" ]] \
    || die "Hostname nach Reboot immer noch '${live:-?}'. Prüfe: pct config ${CTID} | grep hostname"
  log_ok "Hostname nach Reboot: ${live}."
  pct_exec "systemctl is-active --quiet opensign.service && systemctl is-active --quiet docker" \
    || die "Services nach Reboot nicht aktiv — prüfe: pct exec ${CTID} -- journalctl -u opensign --no-pager -n 50"
  pct_exec "curl -fsS -m 10 http://127.0.0.1:${UI_PORT}/ -o /dev/null" \
    || die "Web-UI nach Reboot nicht erreichbar."
  log_ok "Reboot-Test bestanden (Hostname + Services + Web-UI)."
}

main "$@"
