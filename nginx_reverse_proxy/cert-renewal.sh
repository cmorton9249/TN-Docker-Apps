docker run --rm \
  --env-file /mnt/Main/AppData/nginx-proxy/acme/acme.env \
  -v /mnt/Main/AppData/nginx-proxy/acme:/acme.sh \
  -v /mnt/Main/AppData/nginx-proxy/certs:/certs \
  neilpang/acme.sh \
  --cron --home /acme.sh \
&& docker exec dmz-proxy nginx -s reload
