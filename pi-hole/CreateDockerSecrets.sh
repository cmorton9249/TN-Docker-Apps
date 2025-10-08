SECRETS_DIR='/mnt/Main/AppData/secrets'
sudo mkdir -p "$SECRETS_DIR"
sudo sh -c 'printf "%s" "check-lastpass-for-current-value" > '$SECRETS_DIR/pihole_password.txt'
sudo chown root:root '$SECRETS_DIR'/pihole_password.txt
sudo chmod 600 '$SECRETS_DIR'/pihole_password.txt
