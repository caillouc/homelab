# Homelab setup

* [ZFS](https://github.com/openzfs/zfs) : File system
* [Wireguard](https://www.wireguard.com/) : vpn server
* [Wg-easy](https://github.com/wg-easy/wg-easy) : vpn admin frontend
* [Caddy](https://github.com/caddyserver/caddy) : reverse proxy
* [Dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) : dns server
* [Samba](https://github.com/dperson/samba) : shared folder
* [Immich](https://github.com/immich-app/immich) : photo managment
* [Joplin](https://github.com/laurent22/joplin/) : markdown note app
* [Uptime Kuma](https://github.com/louislam/uptime-kuma) : monitoring

## NOTES

* Raspberry pi needs its vpn config to have a `PersistentKeepalive` so that magenta can reach it anytime
* Raspberry pi script that verifies if vpn is running (setup in crontab at midnight) : 
```bash
#!/bin/bash

# Check if the WireGuard interface is up
if ! wg show wg0 | grep -q "interface: wg0"; then
    echo "WireGuard is not connected. Attempting to start..."
    sudo systemctl restart wg-quick@wg0
else
    echo "WireGuard is already connected."
fi
```
* Raspberry pi that listen for zfs with mbuffer and corresponding `systemd` service: 
```shell
#!/bin/bash

TARGET_DATASET="magenta-backup/data"
MBUFFER_PORT=9090
MBUFFER_MEM="1G"
MBUFFER_BLOCK="128k"

sudo mbuffer -q -Q -m "$MBUFFER_MEM" -s "$MBUFFER_BLOCK" -I "$MBUFFER_PORT" | \
sudo zfs receive -u "$TARGET_DATASET"
```
```
[Unit]
Description=ZFS Receive via mbuffer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/home/pierre/zfs-receive-mbuffer.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
* zfs mbuffer receive should also be in a cron job since when receiving is done, the process is terminated
* Set a timezone if you want your cron job to run when expected
* `zfs-backup.sh` in a cron job a 3am (since immich database backup is at 2am)
* For magenta to communicate with vpn peer the right ip route should be set : `ip route add 10.8.0.0/24 via 10.10.0.10`
  * This should not be done with `netplan` since `10.10.0.10` resides in a docker network
  * The following service is then used
```
[Unit]
Description=Add Docker-dependent routes
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/home/pierre/homelab/script/docker-routes.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```
