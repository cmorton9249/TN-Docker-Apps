# 🧭 ATM10 Server Upgrade Runbook
**Applies to:** ATM10 Minecraft servers running NeoForge (Linux + systemd)  
**Purpose:** Safely upgrade ATM10 while preserving world data, world symlinks, and server configs.

---

## 1. Overview
This runbook covers:

1. Pre-upgrade checks  
2. Downloading the new ATM10 server from CurseForge  
3. Running the NeoForge installer safely in staging  
4. Cleaning staging & production directories  
5. Copying upgrade contents into the live server  
6. Validation  
7. Rollback

Your structure:

```
/srv/minecraft/bin/
/srv/minecraft/data/world
/srv/minecraft/backups
/srv/minecraft/upgrade-stage
```

---

## 2. Pre‑Upgrade Steps

### Stop the server
```bash
sudo systemctl stop atm10
```

### Create a fresh world backup
```bash
sudo -u minecraft /srv/minecraft/bin/backup-world.sh
```

Confirm backup exists in `/srv/minecraft/backups`.

---

## 3. Prepare Staging Directory

```bash
mkdir -p /srv/minecraft/upgrade-stage
cd /srv/minecraft/upgrade-stage
```

---

## 4. Download ATM10 Server From CurseForge

Example (ATM10 5.3.1):

```bash
wget -O atm10-server.zip "https://www.curseforge.com/api/v1/mods/533097/files/7199400/download"
unzip atm10-server.zip -d atm10-5.3.1
```

---

## 5. Run the NeoForge Installer

```bash
cd /srv/minecraft/upgrade-stage/atm10-5.3.1
bash startserver.sh
```

The installer will download dependencies and then stop when it reaches the EULA prompt.  
**Stop the script without accepting EULA** — installation is complete.

---

## 6. Cleaning Staging & Production (Upgrade Clean Script)

Save the script below as:

```
atm10-upgrade-clean.sh
```

```bash
#!/usr/bin/env bash
# Cleans staging and production directories before an ATM10 upgrade.
# Usage: ./atm10-upgrade-clean.sh <staging_dir>

set -euo pipefail

staging_dir="${1:-}"
bin_dir="/srv/minecraft/bin"

if [[ ! -d "$staging_dir" ]]; then
    echo "Error: staging directory '$staging_dir' does not exist."
    exit 1
fi

echo "=== Cleaning Staging Directory: $staging_dir ==="
rm -rf "$staging_dir/world"        "$staging_dir/usercache.json"        "$staging_dir/usernamecache.json"        "$staging_dir/whitelist.json"        "$staging_dir/banned-ips.json"        "$staging_dir/banned-players.json"

echo "=== Removing server-generated files from Production Bin ==="
rm -f "$bin_dir/usercache.json"       "$bin_dir/usernamecache.json"       "$bin_dir/whitelist.json"       "$bin_dir/banned-ips.json"       "$bin_dir/banned-players.json"

echo "=== Clean complete. You may now copy staging → bin safely. ==="
```

Run it:

```bash
bash atm10-upgrade-clean.sh ./upgrade-stage/atm10-5.3.1
```

---

## 7. Copy Staging Into Production

```bash
sudo chown -R minecraft:minecraft /srv/minecraft/upgrade-stage
rsync -av --progress /srv/minecraft/upgrade-stage/atm10-5.3.1/ /srv/minecraft/bin/
```

This **does not overwrite** your world symlink or your custom configs.

---

## 8. Fix Permissions

```bash
sudo chown -R minecraft:minecraft /srv/minecraft/bin
```

---

## 9. Start the Server

```bash
sudo systemctl start atm10
sudo systemctl status atm10
```

---

## 10. Validation

Check logs:

```bash
sudo journalctl -u atm10 -f
```

Verify NeoForge version:

```bash
grep NEOFORGE_VERSION /srv/minecraft/bin/startserver.sh
```

Verify players can connect.

---

## 11. Rollback Procedure

If needed:

1. Stop the server  
   ```bash
   sudo systemctl stop atm10
   ```

2. Restore world backup  
   ```bash
   tar -xzf /srv/minecraft/backups/<backup>.tar.gz -C /srv/minecraft/data/world
   ```

3. Restore previous bin snapshot  
4. Start the server  
   ```bash
   sudo systemctl start atm10
   ```

## End of Runbook
