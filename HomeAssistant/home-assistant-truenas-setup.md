# Home Assistant on TrueNAS Scale — Build & Operations Guide

A reference for deploying Home Assistant as a custom Docker app on TrueNAS Scale, placed on an isolated IoT VLAN via macvlan, reached internally and externally through an existing nginx reverse proxy in the DMZ with wildcard TLS.

## Architecture summary

- **Home Assistant** runs as a TrueNAS Custom App (Docker) pinned to a static IP on the **IoT VLAN** via macvlan, giving it L2 presence with IoT devices.
- The **TrueNAS host has no IP on the IoT VLAN**; only the container does.
- The **DMZ nginx reverse proxy** terminates TLS (wildcard cert) and forwards to HA. HA is never exposed directly.
- **Cloudflare** fronts external access (proxied, Full (Strict)). Internal clients bypass it via Pi-hole split-horizon DNS.
- The **UDM** brokers all cross-VLAN traffic with narrowly scoped rules.

Example addressing used throughout (substitute your own):

| Element | Value |
|---|---|
| IoT subnet / gateway | `192.168.101.0/24` / `192.168.101.1` |
| Home Assistant container | `192.168.101.5` (outside the IoT DHCP pool) |
| DMZ reverse proxy | `192.168.50.230` |
| Primary LAN / UDM | `192.168.1.0/24` / `192.168.1.1` |
| Pi-hole | `192.168.1.253` |
| Public hostname | `homeassistant.teammorton.net` |
| HA config dataset | `/mnt/Main/AppData/HomeAssistant` → `/config` |

## The files and how each is applied

| File | Where it lives | Purpose | Applying a change |
|---|---|---|---|
| `ha.yaml` | Pasted into **TrueNAS Apps → Custom App** (not read from `/config`) | Container definition: image, IP, volume | Edit the app in the TrueNAS UI and save; the container redeploys |
| `configuration.yaml` | `/mnt/Main/AppData/HomeAssistant/` | Root config; pulls in the other files; proxy trust | **Check Configuration**, then **full restart** |
| `templates.yaml` | same folder | Template sensors (washer/dryer door) | First time: full restart. After that: **Reload Template Entities** |
| `automations.yaml` | same folder | Automations (managed by the HA UI) | Edit in the UI; if edited by hand, **Reload Automations** |
| `scripts.yaml`, `scenes.yaml` | same folder | Currently empty; must exist because `configuration.yaml` includes them | Nothing to do; HA creates them on first run |

Rationale: `configuration.yaml` is the only file HA reads directly. Everything else is reached through its `!include` lines, so a file that is not referenced there is silently ignored. Validate before applying, since a YAML error in the root config can stop HA from starting.

Edit files from the TrueNAS shell or the SMB share (`\\192.168.1.10\AppData\HomeAssistant`). Use spaces, never tabs.

---

## Part A — Network and infrastructure

### A1. TrueNAS host networking

The host receives the IoT VLAN as a tagged subinterface, bridged, with **no IP** so the host stays off the segment.

1. **UDM:** the switch port feeding the NAS NIC carries the IoT VLAN **tagged** (Native VLAN: None). Add the IoT network to that port's tagged VLANs.
2. **TrueNAS → Network → Interfaces → Add → VLAN:** name `vlan101`, parent = the NIC carrying the trunk, VLAN tag = the IoT network's actual VLAN ID, DHCP off, no IP alias.
3. **Add → Bridge:** name `br101`, member `vlan101`, Enable Learning on, Aliases empty.
4. **Test Changes**, confirm connectivity, then **Save Changes**.

Rationale: the VLAN tag must match on both the UDM and the NAS; it is independent of the subnet's third octet. An IP-less bridge mirrors how the DMZ bridge is already built and keeps the host out of the IoT segment.

### A2. macvlan Docker network

```bash
sudo docker network create -d macvlan \
  --subnet=192.168.101.0/24 \
  --gateway=192.168.101.1 \
  -o parent=br101 \
  ha-vlan
```

> **Naming:** the TrueNAS custom-app engine validates names against `^[a-z]([-a-z0-9]*[a-z0-9])?$` — lowercase letters, digits, and hyphens only. No uppercase, no underscores. This applies to the network name and the app name. (`ha-vlan` is valid; `HA_VLAN` is not.)

Verify:

```bash
sudo docker network inspect ha-vlan
```

Confirm `parent` = `br101`, subnet `192.168.101.0/24`, gateway `192.168.101.1`.

Rationale: the subnet must match the real IoT L2 exactly, but declaring it does not reserve addresses; only IPs assigned to containers are used. The TrueNAS app engine accepts only lowercase letters, digits and hyphens in names (`^[a-z]([-a-z0-9]*[a-z0-9])?$`), so `ha-vlan` works and `HA_VLAN` does not.

### A3. UDM firewall (zone-based)

Inter-zone traffic is deny-by-default. Add scoped allows by destination host and port, above the zone's catch-all.

| # | Purpose | Src zone | Source | Dst zone | Destination | Port | Action |
|---|---|---|---|---|---|---|---|
| 1 | LAN admin to HA | Internal | LAN (or an admin host) | IoT | `192.168.101.5` | TCP 8123 | Allow |
| 2 | Reverse proxy to HA | DMZ | `192.168.50.230` | IoT | `192.168.101.5` | TCP 8123 | Allow |
| 3 | HA outbound internet | IoT | `192.168.101.5` | External | any | TCP 443 | Allow (already satisfied if IoT → External is Allow) |

Rationale: rule 2 pins the source to the proxy so a DMZ compromise cannot roam IoT. Return traffic is stateful, so no reverse rules are needed. Leave IoT → Internal and IoT → DMZ at default deny.

**Optional: UniFi Protect integration (HA to the UDM).** Protect answers on the UDM's own IP (`192.168.1.1:443`), which the UDM evaluates in the **Gateway** zone. IoT → Gateway is Allow All by default, so every IoT device can reach the router's management plane. Close it with source-scoped rules, in this order, all IoT → Gateway with destination `192.168.1.1`:

| Order | Name | Source | Port | Action |
|---|---|---|---|---|
| 1 | IoT DNS to gateway | IoT (any) | 53 TCP+UDP | Allow |
| 2 | IoT DHCP to gateway | IoT (any) | 67 UDP | Allow |
| 3 | HA to UniFi Protect | `192.168.101.5` | 443 TCP | Allow |
| 4 | Allow mDNS | (built-in) | 5353 UDP | Allow |
| 5 | Block IoT to gateway mgmt | IoT (any) | 443, 22 TCP | **Block** |
| 6 | Allow All Traffic | (built-in, locked) | any | Allow |

Rationale: the built-in Allow All at the bottom cannot be edited, but a Block placed above it overrides it (first match wins). HA's allow must sit above the block because both target the same socket (`192.168.1.1:443`); only the source differs. Use a dedicated **local Viewer-role Protect user** for the integration, not an admin account: the firewall limits reachability, the account limits capability.

Verify from a throwaway container that stands in for a generic IoT device (HA itself holds `.5`):

```bash
sudo docker run --rm -it --network ha-vlan --ip 192.168.101.6 alpine sh -c "
  apk add -q curl;
  curl -k -sS -m 4 -o /dev/null -w '%{http_code}\n' https://192.168.1.1/ || echo BLOCKED;
  nslookup google.com 192.168.1.1 >/dev/null 2>&1 && echo DNS-OK || echo DNS-FAIL"
```

Expected: `BLOCKED` on 443, `DNS-OK`. A working Protect camera in HA confirms the allow rule for `.5`.

### A4. DNS (split-horizon, Pi-hole v6)

1. **Local DNS record:** `homeassistant.teammorton.net` → `192.168.50.230`.
2. **Suppress IPv6 leakage.** Pi-hole admin → Settings → switch to **Expert** → All settings → `misc.dnsmasq_lines`, add one line:
   ```
   local=/teammorton.net/
   ```
   Save.

Rationale: a local A record alone lets AAAA queries fall through to public DNS, which returns Cloudflare's IPv6 edge. IPv6-preferring clients then hairpin out through Cloudflare and fail. `local=/teammorton.net/` makes Pi-hole authoritative for the domain, so AAAA returns empty and clients use the IPv4 record. Side effect: every `teammorton.net` name used internally needs its own Pi-hole record. When IPv6 is deployed later, add AAAA local records under the same domain.

Verify from a client (`ipconfig /flushdns` first):

```cmd
nslookup homeassistant.teammorton.net
```

Expect only `192.168.50.230`, with no `2606:4700:...` addresses.

### A5. Wildcard TLS certificate (acme.sh, DNS-01)

Issue (Cloudflare DNS plugin; credentials live in `acme.env`):

```bash
docker run --rm \
  --env-file /mnt/Main/AppData/nginx-proxy/acme/acme.env \
  -v /mnt/Main/AppData/nginx-proxy/acme:/acme.sh \
  -v /mnt/Main/AppData/nginx-proxy/certs:/certs \
  neilpang/acme.sh \
  --issue --home /acme.sh \
  --dns dns_cf \
  -d "teammorton.net" -d "*.teammorton.net"
```

**Install to the filenames nginx mounts** (the `-d` here is the cert's main domain — the first `-d` from issue):

```bash
docker run --rm \
  --env-file /mnt/Main/AppData/nginx-proxy/acme/acme.env \
  -v /mnt/Main/AppData/nginx-proxy/acme:/acme.sh \
  -v /mnt/Main/AppData/nginx-proxy/certs:/certs \
  neilpang/acme.sh \
  --install-cert --home /acme.sh \
  -d "teammorton.net" \
  --key-file /certs/privkey.pem \
  --fullchain-file /certs/fullchain.pem \
  --reloadcmd "echo cert installed"
```

Verify the SAN covers the wildcard and apex:

```bash
openssl x509 -in /mnt/Main/AppData/nginx-proxy/certs/fullchain.pem -noout -subject -ext subjectAltName -dates
```

Expect `DNS:*.teammorton.net, DNS:teammorton.net` and a `notAfter` ~90 days out. The existing `--cron` renewal job renews the wildcard automatically (keyed by main domain) using the same DNS-01 method — no cron change needed.

---

## 7. nginx reverse proxy vhost

The proxy container mounts its config from host paths. Confirm the mappings:

```bash
sudo docker inspect dmz-proxy --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
```

Typical layout:

- `…/conf/sites` → `/etc/nginx/conf.d` (vhost files; the main `nginx.conf` includes `/etc/nginx/conf.d/*.conf`)
- `…/certs` → `/etc/ssl/certs` (certificate files)
- `…/conf/nginx.conf` → `/etc/nginx/nginx.conf` (main config, holds the `http` block)

Place the vhost file in the **host directory that maps to `/etc/nginx/conf.d`** (e.g. `…/conf/sites/homeassistant.conf`). Use the **container-side** cert paths in the config.

```nginx
# homeassistant.conf
server {
  listen 80;
  server_name homeassistant.teammorton.net;
  return 301 https://$host$request_uri;
}

server {
  listen 443 ssl;
  http2 on;
  server_name homeassistant.teammorton.net;

  ssl_certificate     /etc/ssl/certs/fullchain.pem;
  ssl_certificate_key /etc/ssl/certs/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;

  location / {
    proxy_pass http://192.168.101.5:8123;
    proxy_http_version 1.1;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade           $http_upgrade;
    proxy_set_header Connection        $connection_upgrade;
  }
}
```

> The `$connection_upgrade` variable comes from a `map $http_upgrade $connection_upgrade { … }` block that must exist in the `http` block of the main `nginx.conf`. This is required for Home Assistant's WebSocket frontend.

Validate and reload (macvlan proxy listens directly on its IP — reload via exec):

```bash
sudo docker exec dmz-proxy nginx -t && sudo docker exec dmz-proxy nginx -s reload
```

`nginx -t` must pass before the reload runs; a valid reload is zero-downtime for existing connections.

---

## 8. Home Assistant — trust the reverse proxy

HA rejects proxied requests unless the proxy's IP is explicitly trusted. Edit `configuration.yaml` in the mounted config directory (`/mnt/Main/AppData/HomeAssistant/configuration.yaml`):

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 192.168.50.230
```

- Both keys are required together.
- The value is the **proxy's** IP, not the client's.
- If an `http:` block already exists, merge these keys into it rather than adding a second block.

Changes to the `http:` integration require a **full restart**:

```bash
sudo docker restart homeassistant
```

---

## 9. Verify

1. Browse to `https://homeassistant.teammorton.net` from a LAN client.
2. TLS is valid (wildcard cert), and Home Assistant's onboarding/welcome screen loads.
3. Complete onboarding to create the admin account.

---

## Reference: file and value checklist

| Item | Location / value |
|---|---|
| TrueNAS VLAN interface | `vlan101`, tag = configured IoT VLAN ID, parent = trunk NIC, no IP |
| TrueNAS bridge | `br101`, member `vlan101`, no IP |
| macvlan network | `ha-vlan`, parent `br101`, `192.168.101.0/24`, gw `.1` |
| HA container IP | `192.168.101.5` (outside DHCP pool) |
| HA config dataset | `/mnt/Main/AppData/HomeAssistant` → `/config` |
| Proxy IP | `192.168.50.230` |
| Cert files (host) | `…/nginx-proxy/certs/{fullchain,privkey}.pem` |
| Cert files (container) | `/etc/ssl/certs/{fullchain,privkey}.pem` |
| vhost file | `…/nginx-proxy/conf/sites/homeassistant.conf` |
| HA `trusted_proxies` | `192.168.50.230` |
| Public hostname | `homeassistant.teammorton.net` |
