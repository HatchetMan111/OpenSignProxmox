# OpenSign auf Proxmox — Einzeiler-Installation (Community-Scripts-Stil)

[OpenSign](https://github.com/OpenSignLabs/OpenSign) — freie Open-Source **DocuSign-Alternative**
(PDF signieren, Templates, Multi-Signer, Audit-Trail). Stack: **Node.js (Parse-Server) + React +
MongoDB + Caddy**, ausgeliefert als Docker-Images (`opensign/opensign:main`,
`opensign/opensignserver:main`). Läuft **vollständig lokal**, Dokumente bleiben im LXC
(`USE_LOCAL=true`, Volume `opensign-files`).

> Ressourcen: min. **2 vCPU / 2 GB RAM / 10 GB**, empfohlen **2 vCPU / 4 GB RAM / 15 GB**
> (Mongo + Node sind hungrig — bei <2 GB wird es instabil). Dieses Script nutzt einen
> **privilegierten LXC mit nesting** für Docker. Wer strikt unprivilegiert will:
> `UNPRIVILEGED=1 pct set <CTID> --features nesting=1,keyctl=1` — Docker geht dann auch,
> ist aber weniger fehlertolerant.

## ⚠️ Wichtig: Platzhalter `USER` nicht verwenden

Der Aufruf mit `https://raw.githubusercontent.com/USER/opensign-proxmox/...` führt zu
**keiner Ausgabe** (zwei neue Prompts, nichts passiert) — `wget -q` schluckt den 404-Fehler
still. Für **dieses Repo** lautet der fertige Einzeiler:

## Installation (copy-paste, als root auf dem Proxmox-Host)

Voraussetzungen: Proxmox VE 8+, Root-Shell (`root@Prox`), Internet/DNS auf dem Host,
genug Platz auf `local-lvm`/`local`, DHCP (oder statische IP siehe unten).

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenSignProxmox/main/install/opensign.sh)"
```

Mit Trace bei Problemen:

```bash
bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenSignProxmox/main/install/opensign.sh)"
```

Das Script ist **idempotent** (`set -euo pipefail` + `trap ERR` mit kompletter
Fehlerkette): Bei vorhandener CTID wird nichts neu erstellt, sondern Docker-Setup,
Compose-Files, systemd-Unit und Verifikation erneut ausgeführt.

### Schritt für Schritt

1. Per SSH oder Shell auf den Proxmox-Host (nicht in einen Container).
2. `pveversion` prüfen — muss eine Version ausgeben.
3. Einzeiler oben einfügen, Enter. Dauer: je nach Leitung/Template 5–15 Min.
4. Am Ende steht die URL da (siehe „Erwartete Ausgabe").

### Variablen (oben im Script, per ENV überschreibbar)

| Variable | Default | Bedeutung |
|---|---|---|
| `CTID` | nächste freie ID | `CTID=200 bash -c "$(wget …)"` |
| `HOSTNAME` | `opensign` | LXC-Name (Proxmox-UI + `hostname` im Container, wird auch bei Re-Run nachgezogen) |
| `CPU` / `RAM` / `DISK` | `2` / `4096` / `15` | vCPU / MiB / GB |
| `STORAGE` / `TEMPLATE_STORAGE` | `local-lvm` / `local` | Rootfs- / Template-Storage |
| `BRIDGE` / `IP_MODE` / `GATEWAY` | `vmbr0` / `dhcp` | z.B. `IP_MODE=192.168.1.50/24 GATEWAY=192.168.1.1` |
| `UI_PORT` / `CLIENT_PORT` / `SERVER_PORT` | `3001` / `3000` / `8080` | Caddy-UI / Frontend / API |
| `UNPRIVILEGED` | `0` | `1` für unprivilegiert (nesting bleibt an) |

Beispiel statische IP:

```bash
CTID=210 IP_MODE=192.168.1.50/24 GATEWAY=192.168.1.1 \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenSignProxmox/main/install/opensign.sh)"
```

## Nach der Installation

Erwartete Ausgabe (Beispiel):

```text
[OK]    Container 200 erstellt.
[OK]    Container-IP: 192.168.1.100
[OK]    Docker bereits vorhanden: Docker version 26.x
[OK]    Web-UI antwortet auf localhost:3001
════════════════════════════════════════════════════
  OpenSign ist bereit!
  Web-UI : http://192.168.1.100:3001
  API    : http://192.168.1.100:3001/api/app
  CT-ID  : 200
════════════════════════════════════════════════════
```

1. Browser öffnen: **`http://<LXC-IP>:3001`** → Konto registrieren (lokal).
2. Reboot-Test: `pct reboot 200` → danach `pct exec 200 -- systemctl is-active opensign`
   und URL erneut öffnen (Container hat `onboot: 1`, Service `Restart` via
   `restart: unless-stopped` + `opensign.service` mit `enable`).
3. E-Mail-Versand ist default **aus** (`SMTP_ENABLE=false`). Für Signierungs-Mails
   im Container anpassen und neu starten:
   ```bash
   pct exec 200 -- nano /opt/opensign/.env.prod
   pct exec 200 -- bash -c "cd /opt/opensign && docker compose up -d && systemctl restart opensign"
   ```

## Update / Deinstall

```bash
# Update (neue Images ziehen, MASTER_KEY bleibt erhalten):
pct exec 200 -- bash -c "cd /opt/opensign && docker compose pull && docker compose up -d"

# Script erneut laufen lassen (repariert/verifiziert alles; CTID setzen falls bekannt):
CTID=200 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenSignProxmox/main/install/opensign.sh)"

# Deinstall (Container + Daten unwiderruflich löschen):
pct stop 200 && pct destroy 200
```

## Troubleshooting

**Fall 1: Keine Ausgabe — nur zwei neue Prompts (`root@Prox:~#` … `root@Prox:~#`).**
Ursache fast immer: falsche URL (z.B. noch `USER`-Platzhalter) oder kein Netz/DNS —
`wget -q` zeigt den Fehler nicht. Diagnose (Fehler werden hier **angezeigt**):

```bash
wget -LO - https://raw.githubusercontent.com/HatchetMan111/OpenSignProxmox/main/install/opensign.sh -O /tmp/opensign.sh; echo "exit=$?"
head -5 /tmp/opensign.sh
# Alternativ mit Fehlerausgabe:
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/OpenSignProxmox/main/install/opensign.sh -o /tmp/opensign.sh && bash /tmp/opensign.sh
```

**Fall 2: Script startet, bricht aber ab.** Es druckt Exit-Code, Kommando, Zeile und
Stacktrace. Danach:

```bash
bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenSignProxmox/main/install/opensign.sh)"
pct exec 200 -- systemctl status opensign --no-pager
pct exec 200 -- journalctl -u opensign --no-pager -n 50
pct exec 200 -- docker ps
pct exec 200 -- docker logs caddy-container --tail 50
pct exec 200 -- docker logs OpenSignServer-container --tail 50
pct exec 200 -- docker logs OpenSign-container --tail 50
pct exec 200 -- curl -v http://127.0.0.1:3001/
```

## Dateien in diesem Repo

- `install/opensign.sh` — Host-Script (erstellt LXC + installiert alles, Variablen oben)
- `systemd/opensign.service` — Referenzkopie der Unit (das Script schreibt sie identisch nach `/etc/systemd/system/opensign.service` im LXC)
- `README.md` — diese Datei

## Hinweise / Abweichungen zu Upstream

- Upstream-`docker-compose.yml` nutzt `mongo:latest` + `caddy:latest` und erwartet
  `HOST_URL=https://domain` mit TLS. Für **LAN-IPs ohne Domain** gibt es kein
  Let's-Encrypt-Zertifikat — daher läuft Caddy hier bewusst auf **reinem HTTP
  `:3001`** (`USE_LOCAL=true`, keine S3-/Mailgun-Pflicht).
- Upstream publiziert **keine versionierten Tags** (nur `:main`/`:staging`).
  Mongo (`7.0`) und Caddy (`2-alpine`) sind deshalb gepinnt; OpenSign-Images
  folgen `:main`. Updates = `docker compose pull`.
