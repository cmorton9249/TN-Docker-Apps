# TrueNAS Apps — Pi-hole on 192.168.1.253 (Final)

This document captures the **finished, reproducible** setup for running Pi-hole on TrueNAS SCALE with a dedicated IP **without** macvlan. It uses a **host IP alias** and **port bindings**, with the admin password supplied via a **Compose secret**.

---

## Overview
- **Pi-hole IP:** `192.168.1.253` (host IP alias; TrueNAS GUI bound to a different IP)
- **Data path:** `/mnt/Main/AppData/pihole`
  - `etc-pihole` → mounted to `/etc/pihole`
  - `etc-dnsmasq.d` → mounted to `/etc/dnsmasq.d`
- **Secret path:** `/mnt/Main/AppData/secrets/pihole_password.txt` (no trailing newline)
- **Why this design:** avoids macvlan/ipvlan quirks, lets the host and LAN use Pi-hole, works cleanly with TrueNAS Apps

---

## Final Docker Compose (TrueNAS Apps)
```yaml
version: "3.8"

services:
  pihole:
    image: pihole/pihole:latest
    secrets:
      - pihole_webpasswd
    restart: unless-stopped
    hostname: pi-hole
    environment:
      DNSMASQ_LISTENING: "all"
      ServerIP: "192.168.1.253"
      TZ: "America/New_York"
      WEBPASSWORD_FILE: pihole_webpasswd
    volumes:
      - /mnt/Main/AppData/pihole/etc-pihole:/etc/pihole
      - /mnt/Main/AppData/pihole/etc-dnsmasq.d:/etc/dnsmasq.d
    cap_add:
      - NET_ADMIN
    ports:
      - "192.168.1.253:53:53/udp"
      - "192.168.1.253:53:53/tcp"
      - "192.168.1.253:80:80/tcp"
      - "192.168.1.253:443:443/tcp"
    dns:
      - 1.1.1.1
      - 1.0.0.1

secrets:
  pihole_webpasswd:
    file: /mnt/Main/AppData/secrets/pihole_password.txt
```

> **Note:** Ensure the TrueNAS GUI is not bound to 0.0.0.0:80/443 if you use those ports on `.253`. Scope the GUI to the host’s primary IP in *System Settings → General → GUI*.

---

## Create the Secret (one-time)
```bash
sudo mkdir -p /mnt/Main/AppData/secrets
# Write the password **without a trailing newline**
sudo sh -c 'printf "%s" "YOUR-ADMIN-PASSWORD" > /mnt/Main/AppData/secrets/pihole_password.txt'
sudo chown root:root /mnt/Main/AppData/secrets/pihole_password.txt
sudo chmod 600 /mnt/Main/AppData/secrets/pihole_password.txt
```

## Rotate the Password (later)
```bash
sudo sh -c 'printf "%s" "NEW-ADMIN-PASSWORD" > /mnt/Main/AppData/secrets/pihole_password.txt'
sudo chmod 600 /mnt/Main/AppData/secrets/pihole_password.txt
NAME=$(docker ps --format '{{.Names}}' | grep -i pihole | head -n1)
docker restart "$NAME"
```

## Verify After Deploy
```bash
# Check that the secret is wired up
NAME=$(docker ps --format '{{.Names}}' | grep -i pihole | head -n1)
docker exec -it "$NAME" env | grep WEBPASSWORD_FILE
# Secret should be mounted at /run/secrets/pihole_webpasswd internally
```
If you ever see **“Password already set in config file”** at startup, clear legacy values and restart:
```bash
docker exec -it "$NAME" bash -lc '
  rm -f /etc/pihole/cli_pw
  sed -i -E "s/^\s*WEBPASSWORD=.*/WEBPASSWORD=/" /etc/pihole/setupVars.conf 2>/dev/null || true
  sed -i -E "s/^\s*webserver\.api_password.*/# cleared to use secret/" /etc/pihole/pihole.toml 2>/dev/null || true
'
docker restart "$NAME"
```

---

## Post-Deploy Checklist
- Router DHCP → set DNS to `192.168.1.253` for clients
- Pi-hole UI → `http://192.168.1.253/admin`
- **Interface listening:** *Settings → DNS →* set to **Listen on all interfaces, permit all origins**
- **Upstreams:** keep in `/etc/dnsmasq.d/02-upstreams.conf` if desired (e.g., Cloudflare); send SIGHUP to FTL after changes
- Export a **Teleporter** backup from the UI once you’re happy

---

**Last updated:** 2025-10-07
