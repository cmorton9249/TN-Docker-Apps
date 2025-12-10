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
rm -rf "$staging_dir/world" \
       "$staging_dir/usercache.json" \
       "$staging_dir/usernamecache.json" \
       "$staging_dir/whitelist.json" \
       "$staging_dir/banned-ips.json" \
       "$staging_dir/banned-players.json"

echo "=== Removing server-generated files from Production Bin ==="
rm -f "$bin_dir/usercache.json" \
      "$bin_dir/usernamecache.json" \
      "$bin_dir/whitelist.json" \
      "$bin_dir/banned-ips.json" \
      "$bin_dir/banned-players.json"

echo "=== Clean complete. You may now copy staging → bin safely. ==="
