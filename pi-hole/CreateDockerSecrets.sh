sudo mkdir -p /mnt/tank/apps/secrets
sudo sh -c 'printf "%s" "check-lastpass-for-pihole-secret" > /mnt/tank/apps/secrets/pihole_password.txt'
sudo chown root:root /mnt/tank/apps/secrets/pihole_password.txt
sudo chmod 600 /mnt/tank/apps/secrets/pihole_password.txt
