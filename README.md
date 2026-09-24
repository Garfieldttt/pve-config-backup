# pve-config-backup

A Bash script that backs up the configuration of a Proxmox VE host into one file and
restores it with a dialog TUI, completely or piece by piece, on the same or on another host.

Guest disks are not part of the backup, they belong to Proxmox Backup Server. The tool restores
the guest configurations.

<img width="939" height="466" alt="image" src="https://github.com/user-attachments/assets/9c304bab-ee33-4db6-955c-30fa5f1a59ba" />


## What is backed up

- The cluster database (`config.db`), i.e. all of `/etc/pve`: storages, users, permissions,
  guests, firewall, SDN, HA, jobs, notifications, certificates, ...
- Network, APT sources, the Proxmox VE related host settings (vzdump, kernel and module
  options, ZFS, sysctl, iSCSI, mail, container id ranges, ...), SSH host keys, statistics
- All of `/etc` for manual extraction
- Optionally own files and folders (see below)

The archive is `pvecfg_<host>_<date>.tar.zst`, optionally encrypted (`.gpg`, AES256), with
checksums that are verified before a restore.

## Usage

```
pve-config-backup.sh                         interactive menu
pve-config-backup.sh backup [options]        backup, non-interactive and cron-safe
    -o, --output DIR          target directory (default /var/backups/pve-config-backup)
    -k, --keep N              keep the newest N backups (default 14, 0 = all)
    -e, --encrypt             encrypt, asks for the passphrase
    -p, --passphrase-file F   passphrase from a root-only file, implies -e
    -i, --include PATH        also back up this file or folder
    --copy-to USER@HOST:/DIR  copy the backup to another host via SSH
    --ssh-port N              SSH port of the copy target
    --copy-unencrypted        allow copying an unencrypted backup
    -q, --quiet               output only on errors
pve-config-backup.sh restore FILE [--dry-run] [-p F]
pve-config-backup.sh inspect FILE [-p F]
pve-config-backup.sh schedule                set up the cron job
```

`schedule` asks for time, target directory, retention, encryption and the SSH copy, installs
the script to `/usr/local/sbin` and writes `/etc/cron.d/pve-config-backup`. Errors are mailed
by cron, everything is logged to `/var/log/pve-config-backup.log`.

Keep the backups somewhere that survives a failure of the host, and keep the passphrase in a
password manager: without it an encrypted backup cannot be restored.

## Restore

<img width="939" height="517" alt="image" src="https://github.com/user-attachments/assets/cd6814c6-02b0-4875-b7a0-79702b416e25" />


| Mode | For |
|---|---|
| Full disaster recovery | a freshly installed host becomes the old one (exact, or part by part) |
| Selective migration | another, running host takes over chosen parts |
| Undo | roll a host back to its state before a restore |

Every part and every entry can be chosen, each change is shown as a diff before it is written,
and every restore first saves an undo point. `--dry-run` shows everything without writing.
Entries that exist only on the target are kept. A network change is rolled back automatically
unless it is confirmed.

<img width="939" height="517" alt="image" src="https://github.com/user-attachments/assets/06293cce-a4a4-430b-95b7-7d02b876165d" />


## Copy to another host (SSH)

The menu entry `ssh` sets up a target `user@host:/directory`, tests it and switches the copy
on or off for the scheduled backup.

<img width="939" height="449" alt="image" src="https://github.com/user-attachments/assets/8206c641-c17d-4285-9be4-dc323a53227c" />


The tool creates its own key and shows the line for `~/.ssh/authorized_keys` on the target:

```
command="rrsync -wo /srv/pve-config",restrict ssh-ed25519 AAAA... pve-config-backup@pve
```

With it the key can only write into that directory (no shell, no reading, no deleting). rsync
must be installed on the target; old copies are removed there, for example with
`find /srv/pve-config -name 'pvecfg_*' -mtime +60 -delete`. Copy encrypted backups only.

## Own files and folders

Own scripts, hooks or units can be added in `/etc/pve-config-backup.include` (menu entry
`include`), one path per line:

```
/opt/my-scripts
/usr/local/bin/*.sh
```

On restore they are a part of their own and are only written when chosen.

## Not restorable

- Guest disks: restore them from Proxmox Backup Server.
- Ceph, installed packages, kernel, bootloader, disk and pool layout, the root password.
- General Linux administration (cron, sshd, time sync, fstab, ...); it is in the archive and
  can be extracted by hand: `tar --zstd -xf <backup> -C /tmp/x ./files/etc/<path>`.
- Onto another node name: the node identity (PVE certificates, CA, keys) and cluster
  membership.

## Requirements

Proxmox VE 8 or 9, root. `tar`, `zstd`, `sqlite3`, `jq`, `dialog`, optionally `gpg` and
`rsync`; missing ones are offered for installation.

## License

GPL-3.0, see `LICENSE`.
