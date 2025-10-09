# Reverse Proxy and Certificate Automation (TrueNAS DMZ)

## Overview
This document describes how to deploy an **nginx-based reverse proxy** on TrueNAS SCALE inside a DMZ segment, secured by **automated Let’s Encrypt certificates** issued via **Cloudflare DNS-01** using `acme.sh`.

## Architecture
- **TrueNAS SCALE host** runs Docker Compose.
- **`dmznet` (macvlan)**: isolates DMZ services (e.g., Plex, Minecraft).
- **`dmz-proxy` (nginx)**: reverse proxy exposed on DMZ network, terminating HTTPS.
- **`acme.sh` (ephemeral container)**: issues and renews certificates using Cloudflare DNS API.
- **`svc-acme`**: dedicated non-login service account for automation and renewal cron.
- **Pi-hole DNS override**: internal clients resolve services like `plex.teammorton.net` to internal DMZ IPs.

## Directory Layout

```
/mnt/Main/AppData/nginx-proxy/
├── acme/           # ACME home (account data, config)
│   ├── acme.env    # Cloudflare + ACME environment variables
├── certs/          # Live certificates read by nginx
├── conf/
│   ├── nginx.conf  # Main nginx configuration
│   └── sites/
│       └── plex.conf  # Per-site reverse proxy config
└── logs/           # Access/error logs
```

## nginx Compose Stack

**`/mnt/Main/AppData/nginx-proxy/docker-compose.yml`**
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

## nginx Configuration

**`nginx.conf`**
```nginx
user nginx;
worker_processes auto;
events { worker_connections 1024; }

http {
  include mime.types;
  default_type application/octet-stream;
  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 65;
  include /etc/nginx/conf.d/*.conf;
}
```

**`sites/plex.conf`**
```nginx
server {
  listen 80;
  server_name plex.teammorton.net;
  return 301 https://$host$request_uri;
}

server {
  listen 443 ssl;
  http2 on;
  server_name plex.teammorton.net;

  ssl_certificate     /etc/ssl/certs/fullchain.pem;
  ssl_certificate_key /etc/ssl/certs/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;

  proxy_connect_timeout 10s;
  proxy_send_timeout    3600s;
  proxy_read_timeout    3600s;
  send_timeout          3600s;

  location / {
    proxy_pass http://192.168.50.226:32400;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_request_buffering off;
  }
}
```

## Certificate Automation

### 1. Environment Variables
**`/mnt/Main/AppData/nginx-proxy/acme/acme.env`**
```dotenv
CF_Token=your_cloudflare_token
CF_Zone_ID=your_cloudflare_zone_id
ACME_EMAIL=certs@teammorton.net
TZ=America/New_York
```

### 2. One-Time Certificate Issuance
```bash
APP=/mnt/Main/AppData/nginx-proxy

docker run --rm   --env-file $APP/acme/acme.env   -v $APP/acme:/acme.sh   -v $APP/certs:/certs   neilpang/acme.sh   --issue --dns dns_cf   -d plex.teammorton.net   --keylength ec-256   --home /acme.sh

docker run --rm   --env-file $APP/acme/acme.env   -v $APP/acme:/acme.sh   -v $APP/certs:/certs   neilpang/acme.sh   --install-cert -d plex.teammorton.net --ecc   --fullchain-file /certs/fullchain.pem   --key-file /certs/privkey.pem
```

### 3. Renewal Automation

Create a **service account**:
```bash
useradd -r -m -s /bin/bash svc-acme
usermod -aG docker svc-acme
chown -R svc-acme:svc-acme /mnt/Main/AppData/nginx-proxy/{acme,certs}
chmod 700 /mnt/Main/AppData/nginx-proxy/acme
chmod 750 /mnt/Main/AppData/nginx-proxy/certs
```

Configure **TrueNAS Cron Job**:
- **User:** `svc-acme`
- **Command:**
  ```bash
  docker run --rm     --env-file /mnt/Main/AppData/nginx-proxy/acme/acme.env     -v /mnt/Main/AppData/nginx-proxy/acme:/acme.sh     -v /mnt/Main/AppData/nginx-proxy/certs:/certs     neilpang/acme.sh     --cron --home /acme.sh   && docker exec dmz-proxy nginx -s reload
  ```
- **Frequency:** Daily
- **Description:** Auto-renew TLS certificates and reload nginx

## Validation
Verify the deployment:

```bash
docker exec dmz-proxy nginx -t
docker exec dmz-proxy nginx -s reload
curl -Ik https://plex.teammorton.net
```

Expected output:
```
HTTP/2 200
server: nginx
subject: CN=plex.teammorton.net
issuer: C=US, O=Let's Encrypt, CN=R3
```

## Security Notes
- The `svc-acme` user adheres to the principle of least privilege.
- Certificates are renewed via DNS-01, requiring **no public ports**.
- Nginx runs in a macvlan-isolated DMZ (only ports 80/443 exposed).
- Internal DNS (Pi-hole) resolves `plex.teammorton.net` → 192.168.50.230.

## Outcome
You now have:
- A self-hosted HTTPS reverse proxy inside your DMZ.
- Automatic certificate issuance and renewal via Cloudflare.
- A dedicated service account managing renewals securely.
- Seamless internal HTTPS access to Plex and future web services.
