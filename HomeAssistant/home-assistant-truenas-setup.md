# Home Assistant on TrueNAS Scale — Segmented Network Build

A reference for deploying Home Assistant as a custom Docker app on TrueNAS Scale, placed on an isolated IoT VLAN via macvlan, reached internally and externally through an existing nginx reverse proxy in the DMZ with wildcard TLS.

## Architecture summary

- **Home Assistant** runs as a container pinned to a static IP on the **IoT VLAN**, giving it local L2 presence with IoT devices (including mDNS discovery).
- The **TrueNAS host holds no IP on the IoT VLAN** — only the HA container does, via macvlan. Host isolation is preserved.
- A **reverse proxy in the DMZ** terminates TLS and forwards to HA. HA is never exposed to the internet directly.
- The **UDM brokers all cross-VLAN traffic** through scoped firewall rules.

Example addressing used throughout (substitute your own):

| Element | Value |
|---|---|
| IoT subnet / gateway | `192.168.101.0/24` / `192.168.101.1` |
| Home Assistant container IP | `192.168.101.5` |
| DMZ reverse proxy IP | `192.168.50.230` |
| Primary LAN subnet | `192.168.1.0/24` |
| Public hostname | `homeassistant.teammorton.net` |

> The IoT container IP must sit **outside** the IoT DHCP pool. macvlan does not defend its address against a DHCP lease, so pick an address the DHCP server will never hand out (e.g. below the pool start).

---

## 1. Prepare TrueNAS host networking

The host needs the IoT VLAN delivered to it as a tagged subinterface, then bridged, with **no IP assigned** (so the host stays off the segment; only the container gets an address).

1. **Trunk the VLAN to the NAS port.** On the UDM, ensure the switch port feeding the NAS NIC carries the IoT VLAN **tagged**. (Match the NIC already used for other tagged VLANs rather than consuming a separate port, unless physical separation is desired.)
2. **TrueNAS → Network → Interfaces → Add → VLAN:**
   - Name: `vlan101` (example)
   - Parent Interface: the active NIC carrying the trunk
   - VLAN Tag: the IoT VLAN's 802.1Q tag *(note: the VLAN tag is independent of the subnet's third octet — use the actual configured tag)*
   - DHCP: off, IPv6: off, **no IP alias**
3. **Add → Bridge:**
   - Name: `br101` (example)
   - Bridge Members: the VLAN interface created above (`vlan101`)
   - Enable Learning: on
   - **Aliases: empty — no IP**
4. **Test Changes**, confirm connectivity is retained, then **Save Changes.** These persist as native TrueNAS config across reboots.

> The VLAN **tag** must match on both ends — the UDM network's configured VLAN ID and the TrueNAS subinterface tag. The subnet is independent of the tag.

---

## 2. Create the macvlan Docker network

Created once from the console, referenced as an external network by the app. The subnet/gateway must exactly match the real IoT L2; the subnet declaration does not reserve or claim addresses — only explicitly assigned container IPs are used.

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

---

## 3. Deploy Home Assistant (TrueNAS Custom App)

**Apps → Discover Apps → (top-right) → Install via YAML.**

- **Name:** `homeassistant-tn` (lowercase/hyphen only)
- **Custom Config:**

```yaml
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    restart: unless-stopped
    environment:
      - TZ=America/New_York
    volumes:
      - /mnt/Main/AppData/HomeAssistant:/config
    networks:
      ha-vlan:
        ipv4_address: 192.168.101.5

networks:
  ha-vlan:
    external: true
```

- Set the `volumes` host path to your own dataset.
- Use `TZ` for timezone rather than mounting `/etc/localtime` (the bind-mount can misbehave on Scale).

Save. First boot takes a minute or two while HA initializes `/config` and its database.

> **macvlan host isolation:** the TrueNAS host **cannot** reach the container's macvlan IP directly. Test HA from a LAN client through the UDM, not with `curl` from the NAS shell. This is expected behavior.

---

## 4. UDM firewall configuration (required regardless of prior state)

On a zone-based firewall, inter-zone traffic is deny-by-default once zones exist. Add explicit, **tightly scoped** allows — scope by destination host IP and port, never open whole zones. Note that zones may contain multiple networks; scoping by destination IP keeps rules precise.

| # | Purpose | Src zone | Src | Dst zone | Dst | Dst port | Action |
|---|---|---|---|---|---|---|---|
| 1 | LAN admin access to HA | Internal/LAN | LAN (or admin host) | IoT | `192.168.101.5` | `8123` (TCP) | Allow |
| 2 | Reverse proxy to HA | DMZ | `192.168.50.230` | IoT | `192.168.101.5` | `8123` (TCP) | Allow |
| 3 | HA outbound internet | IoT | `192.168.101.5` | External/WAN | any | `443` (TCP) | Allow |

Rule notes:

- **Rule 1** lets you reach HA directly from the LAN without hairpinning through the proxy.
- **Rule 2** is the external access path — pin the source to the proxy's IP only, so a DMZ compromise can't roam the IoT segment.
- **Rule 3** is required for HA updates and any cloud integrations (e.g. Nest via the SDM API). If the IoT zone already allows outbound internet broadly, this is satisfied; otherwise scope it to the HA host.
- **Stateful return traffic is automatic** — do not add reverse `IoT → LAN`/`IoT → DMZ` allows.
- **Leave `IoT → LAN` and `IoT → DMZ` at default deny.** HA reaching its own IoT-subnet devices is intra-zone and needs no rule.
- Ensure each Allow sits **above** the corresponding zone's catch-all Block rule.

---

## 5. DNS (split-horizon)

Add an internal DNS record so LAN/IoT clients reach the proxy directly instead of routing out to the WAN and back:

- **Internal (Pi-hole / UDM):** `homeassistant.teammorton.net` → `192.168.50.230` (the reverse proxy)
- **External (public DNS):** the hostname → your WAN IP, only if external access is required.

---

## 6. Wildcard TLS certificate (acme.sh, DNS-01)

A wildcard covers every current and future service under the domain, so per-host certs are never needed again. Wildcards require DNS-01 validation. Run with the same containerized invocation used by the renewal cron so paths and credentials align.

**Issue** (Cloudflare DNS shown — adjust `--dns` for your provider):

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
