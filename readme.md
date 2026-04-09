# Homelab setup

* [ZFS](https://github.com/openzfs/zfs) : File system
* [Wireguard](https://www.wireguard.com/) : VPN tunnel protocol
* [Headscale](https://github.com/juanfont/headscale) : Tailscale control server (replaces wg-easy + dnsmasq)
* [Caddy](https://github.com/caddyserver/caddy) : reverse proxy
* [Samba](https://github.com/dperson/samba) : shared folder
* [Immich](https://github.com/immich-app/immich) : photo management
* [Joplin](https://github.com/laurent22/joplin/) : Markdown note app
* [Uptime Kuma](https://github.com/louislam/uptime-kuma) : monitoring

## Structure

Main compose file includes domain-specific stacks:

* `compose/infra/compose.yml` : headscale + caddy
* `compose/immich/compose.yml` : immich services
* `compose/apps/compose.yml` : joplin + uptime-kuma + flash-backend
* `compose/samba/compose.yml` : samba

## NOTES

* Raspberry Pi that listens for ZFS with mbuffer and corresponding `systemd` service:
```shell
#!/bin/bash

TARGET_DATASET="magenta-backup/data"
MBUFFER_PORT=9090
MBUFFER_MEM="1G"
MBUFFER_BLOCK="128k"

sudo mbuffer -q -Q -m "$MBUFFER_MEM" -s "$MBUFFER_BLOCK" -I "$MBUFFER_PORT" | \
sudo zfs receive -uF "$TARGET_DATASET"
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
* ZFS mbuffer receive should also be in a cron job since when receiving is done, the process is terminated
* Backup destination datasets on Raspberry Pi should stay read-only for normal usage, otherwise next incremental receive can fail with "destination has been modified"
* Set a timezone if you want your cron job to run when expected
* `zfs-backup.sh` in a cron job at 3am (since Immich database backup is at 2am)
* To get backup alerts in Uptime Kuma:
    * Create a `Push` monitor in Uptime Kuma
    * Copy the generated push URL (`https://<kuma>/api/push/<token>`)
    * Set `UPTIME_KUMA_PUSH_URL` in `script/zfs-backup.sh`
    * Script sends `status=up` on success and `status=down` on failure automatically
    * Since the backup runs once per day at 3am, set the expected push interval to about `24h` and give it a grace window like `26h` or `30h`
