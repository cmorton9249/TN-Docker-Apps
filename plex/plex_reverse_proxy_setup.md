# Plex Media Server — Secure Remote Access (Option A: Hybrid Reverse Proxy)

This document describes how to deploy **Plex Media Server** with a secure
HTTPS reverse proxy and a direct TCP path for high-bitrate streaming.

## Overview

Architecture:

```
Internet
   │
   ▼
WAN (UDM Pro)
   │ 443,32400/TCP forwarded
   ▼
dmz-proxy  (192.168.50.230)
   │ 443 → nginx → Plex :32400
   │ 32400 → nginx stream → Plex :32400
   ▼
Plex Server (192.168.50.226)
```

Result:  
`https://plex.teammorton.net` serves Plex Web securely;  
clients stream directly via `tcp/32400` for best quality.

---

## 1. DNS

In Cloudflare:

| Record | Type | Target | Proxy Status |
|---------|------|---------|---------------|
| plex | A | _public WAN IP_ | **DNS-only (gray cloud)** |

---

## 2. UniFi / UDM-Pro Configuration

### Port Forwards

| WAN Port | Destination Host | Destination Port | Protocol |
|-----------|------------------|------------------|-----------|
| 443 | 192.168.50.230 | 443 | TCP |
| 32400 | 192.168.50.230 | 32400 | TCP |

### Firewall Rules (Zones View)

1. **WAN → DMZ ALLOW**  
   - TCP 443, 32400  
   - Destination 192.168.50.230  

2. **DMZ → LAN ALLOW (Plex only)**  
   - TCP 32400  
   - Destination 192.168.50.226  

3. Default “Block All” rules remain below.

---

## 3. Docker Compose — nginx Proxy

```yaml
services:
  dmz-proxy:
    image: nginx:stable
    container_name: dmz-proxy
    restart: unless-stopped
    networks:
      dmznet:
        ipv4_address: 192.168.50.230
    volumes:
      - /mnt/Main/AppData/nginx-proxy/conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - /mnt/Main/AppData/nginx-proxy/conf/sites:/etc/nginx/conf.d:ro
      - /mnt/Main/AppData/nginx-proxy/certs:/etc/ssl/certs:ro
      - /mnt/Main/AppData/nginx-proxy/logs:/var/log/nginx

networks:
  dmznet:
    external: true
```

---

## 4. nginx Configuration

### `/etc/nginx/nginx.conf`
```nginx
user  nginx;
worker_processes auto;

events { worker_connections 4096; }

http {
  include       mime.types;
  default_type  application/octet-stream;

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 65;
  keepalive_requests 10000;
  server_tokens off;

  ssl_session_cache   shared:SSL:10m;
  ssl_session_timeout 1d;

  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  include /etc/nginx/conf.d/*.conf;
}

stream {
  # Plex TCP passthrough
  upstream plex_tcp { server 192.168.50.226:32400; }
  server {
    listen 32400 reuseport;
    proxy_connect_timeout 10s;
    proxy_timeout 3600s;
    proxy_pass plex_tcp;
  }
}
```

### `/etc/nginx/conf.d/plex.conf`
```nginx
# Redirect HTTP→HTTPS
server {
  listen 80;
  server_name plex.teammorton.net;
  return 301 https://$host$request_uri;
}

server {
  listen 443 ssl http2;
  server_name plex.teammorton.net;

  ssl_certificate     /etc/ssl/certs/fullchain.pem;
  ssl_certificate_key /etc/ssl/certs/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;

  client_max_body_size 0;
  proxy_connect_timeout 10s;
  proxy_send_timeout 3600s;
  proxy_read_timeout 3600s;
  send_timeout 3600s;

  set $plex_backend http://192.168.50.226:32400;

  # WebSockets
  location ~ ^/(:/)?websockets/ {
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_http_version 1.1;
    proxy_pass $plex_backend;
  }

  # Main proxy
  location / {
    proxy_pass $plex_backend;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_redirect off;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_set_header X-Plex-Client-Identifier $http_x_plex_client_identifier;
    proxy_set_header X-Plex-Device            $http_x_plex_device;
    proxy_set_header X-Plex-Device-Name       $http_x_plex_device_name;
    proxy_set_header X-Plex-Platform          $http_x_plex_platform;
    proxy_set_header X-Plex-Product           $http_x_plex_product;
    proxy_set_header X-Plex-Token             $http_x_plex_token;
    proxy_set_header X-Plex-Version           $http_x_plex_version;
  }
}
```

Reload nginx:

```bash
docker exec dmz-proxy nginx -t && docker exec dmz-proxy nginx -s reload
```

---

## 5. Plex Server Settings

In **Settings → Network → Remote Access**:

| Option | Value |
|--------|--------|
| Manually specify public port | ✅ 32400 |
| Secure connections | Preferred (then Required) |
| Custom server access URLs | `https://plex.teammorton.net` |

Restart Plex Media Server.

---

## 6. Verification

From outside your network:

```powershell
# HTTPS path
curl -I https://plex.teammorton.net
# Direct TCP
Test-NetConnection plex.teammorton.net -Port 32400
```

Expected results:

- `HTTP/1.1 401 Unauthorized` (from Plex)  
- `TcpTestSucceeded : True`

In Plex Web, **Settings → Remote Access** should read  
> ✅ Fully accessible outside your network

Clients report **Direct (Secure)** connections.

---

## 7. Maintenance

- **Reload nginx** after certificate renewals:
  ```bash
  docker exec dmz-proxy nginx -s reload
  ```
- **Disable UPnP/NAT-PMP** in both Plex and UniFi (manual mapping is authoritative).
- **Restrict firewall rules** to TCP only, keeping DMZ→LAN limited to Plex:32400.

---

### Success Indicator

If you see this log line in  
`Plex Media Server.log`:
```
Mapped port successfully to external port 32400
```
your configuration is complete.
