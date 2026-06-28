docker network create -d macvlan \
  --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 \
  --ip-range=192.168.1.192/25 \
  -o parent=br1 \
  primenet

sudo docker network create -d macvlan \
  --subnet=192.168.101.0/24 \
  --gateway=192.168.101.1 \
  -o parent=br101 \
  ha-vlan