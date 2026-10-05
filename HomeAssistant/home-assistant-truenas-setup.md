# Home Assistant on TrueNAS Scale — Build & Operations Guide (v2)

Supersedes `home-assistant-truenas-setup.md`. Same architecture, now including the working configuration files (`ha.yaml`, `configuration.yaml`, `templates.yaml`, `automations.yaml`), the DNS and Cloudflare pieces added after the first build, and the UniFi Protect firewall hardening.

## Architecture summary

- **Home Assistant** runs as a TrueNAS Custom App (Docker) pinned to a static IP on the **IoT VLAN** via macvlan, giving it L2 presence with IoT devices.
- The **TrueNAS host has no IP on the IoT VLAN**; only the container does.
- The **DMZ nginx reverse proxy** terminates TLS (wildcard cert) and forwards to HA. HA is never exposed directly.
- **Cloudflare** fronts external access (proxied, Full (Strict)). Internal clients bypass it via Pi-hole split-horizon DNS.
- The **UDM** brokers all cross-VLAN traffic with narrowly scoped rules.

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

Install to the filenames nginx mounts (`-d` is the main domain, the first `-d` above):

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

Verify:

```bash
openssl x509 -in /mnt/Main/AppData/nginx-proxy/certs/fullchain.pem -noout -subject -ext subjectAltName -dates
```

Expect `DNS:*.teammorton.net, DNS:teammorton.net` and an expiry about 90 days out.

Renewal runs from a cron job on the TrueNAS host and reloads the proxy afterwards:

```bash
docker run --rm \
  --env-file /mnt/Main/AppData/nginx-proxy/acme/acme.env \
  -v /mnt/Main/AppData/nginx-proxy/acme:/acme.sh \
  -v /mnt/Main/AppData/nginx-proxy/certs:/certs \
  neilpang/acme.sh \
  --cron --home /acme.sh \
&& docker exec dmz-proxy nginx -s reload
```

Rationale: wildcards require DNS-01, which needs no inbound port 80. One wildcard covers every current and future service, so no per-host cert work. `--cron` renews by main domain using the same DNS method, so the cron entry never changes.

### A6. nginx reverse proxy vhost

The `dmz-proxy` container bind-mounts its config from the host:

| Host path | Container path | Contents |
|---|---|---|
| `/mnt/Main/AppData/nginx-proxy/conf/nginx.conf` | `/etc/nginx/nginx.conf` | Main config (`http` block, WebSocket `map`) |
| `/mnt/Main/AppData/nginx-proxy/conf/sites` | `/etc/nginx/conf.d` | Vhost files (included by `nginx.conf`) |
| `/mnt/Main/AppData/nginx-proxy/certs` | `/etc/ssl/certs` | Certificate files |

Save as `/mnt/Main/AppData/nginx-proxy/conf/sites/homeassistant.conf`. Use the **container-side** cert paths:

```nginx
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

`$connection_upgrade` comes from a `map $http_upgrade $connection_upgrade { ... }` block in the `http` section of `nginx.conf`. HA's frontend needs WebSockets, so that map must exist.

```bash
sudo docker exec dmz-proxy nginx -t && sudo docker exec dmz-proxy nginx -s reload
```

Rationale: the host folder name (`sites`) is irrelevant; nginx only reads what is mounted at the path its `include` points to. `nginx -t` gates the reload, so a bad config never replaces the running one. The mounts are read-only, so edit from the host.

### A7. Cloudflare and WAN access (external path)

1. **DNS:** an `A` record for `homeassistant` pointing at the WAN IP, **proxied** (orange cloud).
2. **SSL/TLS → Overview:** mode **Full (Strict)**.
3. **UDM port forward:** WAN TCP 443 → `192.168.50.230:443`.
4. **Security rules (in place):** custom rule *US Only Traffic* (block where country is not US) and the AI-crawler block.

Rationale: Flexible mode makes Cloudflare connect to the origin over port 80, where nginx's HTTP→HTTPS redirect creates an infinite loop ("too many redirects"). Full (Strict) connects over 443 and validates the Let's Encrypt cert. These rules protect only the external path; internal clients resolve straight to the proxy and bypass Cloudflare.

---

## Part B — Deploy the container (`ha.yaml`)

`ha.yaml` is the TrueNAS-normalized form of the Custom App definition (keys alphabetized, `True` capitalized by the exporter; functionally identical to what was submitted).

```yaml
networks:
  ha-vlan:
    external: True
services:
  homeassistant:
    container_name: homeassistant
    environment:
      - TZ=America/New_York
    image: ghcr.io/home-assistant/home-assistant:stable
    networks:
      ha-vlan:
        ipv4_address: 192.168.101.5
    restart: unless-stopped
    volumes:
      - /mnt/Main/AppData/HomeAssistant:/config
```

**First deployment**

1. Confirm the `ha-vlan` network exists (A2) and `/mnt/Main/AppData/HomeAssistant` exists.
2. TrueNAS → **Apps → Discover Apps → Install via YAML**.
3. Name: `homeassistant-tn`. Paste the YAML above as the Custom Config. Save.
4. Allow 1–2 minutes for first boot (HA initializes `/config` and its database).

**Changing it later:** Apps → `homeassistant-tn` → Edit, change the YAML, save. Configuration changes inside HA do not go through this file.

Rationale: `external: true` tells the app engine to attach to the pre-built macvlan rather than create its own. Use `TZ` for the timezone; mounting `/etc/localtime` can misbehave on Scale. The static `ipv4_address` is the container's address; the UDM DHCP pool must not include it.

Note: macvlan isolates the host from its own containers. Test HA from a LAN client, not with `curl` from the NAS shell.

---

## Part C — Home Assistant configuration files

All three live in `/mnt/Main/AppData/HomeAssistant/`.

### C1. `configuration.yaml`

```yaml
# Loads default set of integrations. Do not remove.
default_config:

# Load frontend themes from the themes folder
frontend:
  themes: !include_dir_merge_named themes

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
template: !include templates.yaml

http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 192.168.50.230
```

What each block does:

- `default_config`: loads HA's standard integration set.
- `!include` lines: split-file pattern. Each domain lives in its own file, keeping this file short.
- `template: !include templates.yaml`: loads the template sensors in C2. Without this line `templates.yaml` is never read, and Check Configuration still passes.
- `http:`: **required for the reverse proxy.** HA rejects requests carrying forwarded headers unless the sender is a trusted proxy, returning `400 Bad Request`. Both keys are needed together; the value is the **proxy's** IP, not the client's. If an `http:` block already exists, merge into it, because duplicate top-level keys prevent HA from starting.

**Apply:** Developer Tools → YAML → **Check Configuration**; when clean, restart (`sudo docker restart homeassistant` or the UI restart). `http:` and a newly added `template:` key always need a full restart.

### C2. `templates.yaml`

```yaml
- binary_sensor:
    - name: "Washer Door"
      unique_id: washer_door_status
      state: "{{ is_state('binary_sensor.1st_floor_washer_door', 'on') }}"
      availability: "{{ has_value('binary_sensor.1st_floor_washer_door') }}"
    - name: "Dryer Door"
      unique_id: dryer_door_status
      state: "{{ is_state('binary_sensor.1st_floor_dryer_door', 'on') }}"
      availability: "{{ has_value('binary_sensor.1st_floor_dryer_door') }}"
```

Why it exists: the Whirlpool integration forces `device_class: door` on its door sensors, and that reasserts itself on every reload, so the UI override does not stick. Door-type classes (`door`, `window`, `opening`, `garage_door`) are all grouped as security by the auto-generated dashboards. These template sensors mirror the originals but carry **no device class**, so they appear as plain On/Off appliance sensors.

- `state`: mirrors the source (`on` = door open, `off` = closed).
- `availability`: goes unavailable if the Whirlpool entity drops, instead of falsely reporting "closed" to automations.
- `unique_id`: lets you assign an Area and rename the entity in the UI.
- The file starts at the list level because the `template:` key lives in `configuration.yaml`. Do not repeat `template:` here.

**Finish the setup (one time, in the UI):**

1. Set **Area = Laundry Room** on `binary_sensor.washer_door` and `binary_sensor.dryer_door`.
2. Open each Whirlpool original (`binary_sensor.1st_floor_washer_door`, `binary_sensor.1st_floor_dryer_door`) and set **Visible = off**. Do **not** disable them; the templates read them as their data source.
3. Point automations at the new entities.

**Apply:** Check Configuration, then restart the first time. For later edits use Developer Tools → YAML → **Reload Template Entities**.

**Limitation:** YAML-defined template entities cannot be attached to a device (`device_id` is rejected), so on auto-generated dashboards they sit under "Others" instead of on the appliance card. Options: accept it, place them on a manual dashboard card, or recreate them as UI Helpers (Settings → Devices & Services → Helpers → Template), which support device assignment.

**Adding more:** append another `- name:` entry under the same `binary_sensor:` list.

### C3. `automations.yaml`

| Automation | Trigger | Action |
|---|---|---|
| Turn Attic Light Off | Attic switch on for 15 min | Turn the switch off |
| Close Shuttle Bay Doors after 10pm | Daily at 22:00 | If Main Shuttle Bay **or** Shuttle Bay 2 cover is open, send a "Secure the Shuttle Bay" notification to two phones |
| Laundry Room Light off after 30 mins | Laundry Room light on for **15** min | Turn the light off |
| AM Lights On | 06:30 Mon–Fri | Turn on two lights (the first at 100%) |
| AM Lights Off | 07:45 Mon–Fri | Turn both lights off |

Usage notes:

- The file is **managed by the HA UI** (numeric `id` values). Creating or editing automations in the UI rewrites the file and discards hand-written comments. Make changes in the UI; if you edit the file by hand, run **Check Configuration** then **Reload Automations**.
- Triggers, conditions and actions reference `device_id` / `entity_id` hex values. These come from the entity and device registry in `/config/.storage`, so the file is only portable together with that folder. On a fresh HA install the IDs will not resolve; rebuild the automations in the UI instead.
- Notification targets (`notify.chriss_phone`, `notify.caryns_iphone_17_pro`) exist only after each phone has registered with the HA Companion app.
- **Known mismatch:** *Laundry Room Light off after 30 mins* is named for 30 minutes but its trigger is `minutes: 15`. Either rename the automation or change the duration to match your intent.

---

## Part D — Verify and maintain

**Verify**

1. `nslookup homeassistant.teammorton.net` from a LAN client returns only `192.168.50.230`.
2. `https://homeassistant.teammorton.net` loads from the LAN with a valid wildcard cert.
3. The same URL, and the Companion app, work from a cellular connection.
4. Developer Tools → YAML → Check Configuration reports no errors.
5. Developer Tools → States: `binary_sensor.washer_door` and `binary_sensor.dryer_door` exist with no `device_class` attribute, and track the Whirlpool originals.

**Backup**

Back up the entire `/mnt/Main/AppData/HomeAssistant` dataset, including the hidden `.storage` folder, which holds the device/entity registry, UI-created integrations and credentials. A periodic ZFS snapshot of that dataset is the simplest option. Keep `ha.yaml`, `configuration.yaml`, `templates.yaml` and `automations.yaml` in version control or a separate copy as well.

**Quick reference: what to do after each change**

| Changed | Do this |
|---|---|
| `ha.yaml` (container) | Edit the app in TrueNAS and save |
| `configuration.yaml` | Check Configuration, then full restart |
| `templates.yaml` | Check Configuration, then Reload Template Entities |
| `automations.yaml` | Edit in the UI, or Check Configuration then Reload Automations |
| nginx vhost | `docker exec dmz-proxy nginx -t && docker exec dmz-proxy nginx -s reload` |
| Pi-hole `dnsmasq_lines` | Save in the Pi-hole UI |
| Certificate | Automatic via cron |
| New `teammorton.net` service | Add a Pi-hole local record, an nginx vhost and (if external) a Cloudflare record |
