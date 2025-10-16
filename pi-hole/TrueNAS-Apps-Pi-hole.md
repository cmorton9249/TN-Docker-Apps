# TrueNAS Apps — Pi-hole on 192.168.1.253 (Final)

This document captures the **finished, reproducible** setup for running Pi-hole on TrueNAS SCALE with a dedicated IP using a custom Docker network (`primenet`) and static IP assignment, with the admin password supplied via a **Compose secret**.

---

## Overview
- **Pi-hole IP:** `192.168.1.253` (static IP via Docker network `primenet`)
- **Docker network:** `primenet` (external, must exist before deploy)
- **Data path:** `/mnt/Main/AppData/pihole`
  - `etc-pihole` → mounted to `/etc/pihole`
  - `etc-dnsmasq.d` → mounted to `/etc/dnsmasq.d`
- **Secret path:** `/mnt/Main/AppData/secrets/pihole_password.txt` (no trailing newline)
- **Why this design:** avoids macvlan/ipvlan quirks, provides clean network isolation, works cleanly with TrueNAS Apps

---

## Final Docker Compose (TrueNAS Apps)
```yaml
networks:
  primenet:
    external: true
services:
  pihole:
    image: pihole/pihole:latest
    secrets:
      - pihole_webpasswd
    restart: unless-stopped
    networks:
      primenet:
        ipv4_address: 192.168.1.253
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
    dns:
      - 1.1.1.1
      - 1.0.0.1
secrets:
  pihole_webpasswd:
    file: /mnt/Main/AppData/secrets/pihole_password.txt
```


> **Note:** The `primenet` network must exist and be configured with the correct subnet and gateway. Ensure no IP conflicts on your LAN. The TrueNAS GUI should not be bound to the same IP as Pi-hole.

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
