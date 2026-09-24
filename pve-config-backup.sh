#!/bin/bash
# pve-config-backup.sh - Back up the configuration of a Proxmox VE host into a single file and
# restore it, fully or selectively, on the same or on another host.
#
# The archive holds a consistent dump of the cluster configuration database (pmxcfs,
# /var/lib/pve-cluster/config.db), a file copy of /etc/pve, the host's own configuration from
# /etc (network, apt, ssh, cron, kernel/boot, modules, ...), the RRD statistics and a set of
# reference outputs (NICs with MAC addresses, ZFS pools, LVM, disks, PCI devices, packages).
# Guest disks are NOT part of it: those belong to Proxmox Backup Server.
#
# Restore modes (chosen in the TUI):
#   Full disaster recovery  exact: a freshly installed host becomes the old one (config.db is
#                           replaced, the documented pmxcfs recovery), plus local /etc parts;
#                           or selective: every part and entry chosen one by one
#   Selective migration     take over chosen parts (storages, users, guests, firewall, SDN,
#                           HA, network, ...) onto another, running host
#   Undo                    roll a host back to one of its own backups (the undo point)
#
# Usage:
#   pve-config-backup.sh                         interactive dialog menu
#   pve-config-backup.sh backup [options]        create a backup (non-interactive, cron-safe)
#       -o, --output DIR          target directory (default /var/backups/pve-config-backup)
#       -k, --keep N              keep the newest N backups of this host in DIR (default 14, 0 = all)
#       -e, --encrypt             encrypt with a passphrase (gpg, AES256)
#       -p, --passphrase-file F   read the passphrase from F (root-owned, mode 600); implies -e
#       -i, --include PATH        also back up this file or folder (repeatable; permanent
#                                 entries go into /etc/pve-config-backup.include)
#       --copy-to USER@HOST:/DIR  copy the backup to another host via SSH (rsync, dedicated key
#                                 /root/.ssh/pve-config-backup_ed25519; set up with 'schedule')
#       --ssh-port N              SSH port of the copy target (default 22)
#       --copy-unencrypted        allow copying an unencrypted backup (it holds passwords/keys)
#       -q, --quiet               print nothing unless an error occurs
#   pve-config-backup.sh restore FILE [--dry-run] [-p F]
#   pve-config-backup.sh inspect FILE [-p F]
#   pve-config-backup.sh schedule                set up / change / remove the cron job
#
# Requires: root on a Proxmox VE node. Tools: tar, zstd, sqlite3, jq (backup);
#           dialog, diff (restore); gpg (encryption). Missing ones are offered for install.
#
# Author: Garfieldttt (Thomas Rzen)

set -uo pipefail
export LC_ALL=C LANG=C
umask 077

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
VERSION="0.7.2"
PROG="pve-config-backup"
BACKTITLE="PVE Config Backup v$VERSION"
LOGFILE="/var/log/pve-config-backup.log"
DEFAULT_DIR="/var/backups/pve-config-backup"
PRE_DIR="$DEFAULT_DIR/pre-restore"
NET_RB_DIR="$DEFAULT_DIR/net-rollback"
CRON_FILE="/etc/cron.d/pve-config-backup"
INCLUDE_FILE="/etc/pve-config-backup.include"   # own files and folders, one path per line
INSTALL_PATH="/usr/local/sbin/pve-config-backup"
LOCK_FILE="/run/pve-config-backup.lock"
RB_UNIT="pve-config-backup-net-rollback"
PVE_DIR="/etc/pve"
DB="/var/lib/pve-cluster/config.db"
RRD_DIR="/var/lib/rrdcached/db"
DEFAULT_KEEP=14
PRE_KEEP=5

QUIET=0
DRY_RUN=0
TMPDIRS=()
PASSFILE_TMP=""
BACKUP_RESULT=""
EXTRA_INCLUDES=()   # own paths given with -i
SSH_KEY="/root/.ssh/pve-config-backup_ed25519"   # key for copying backups to another host
COPY_TO=""          # user@host:/dir of the copy target
SSH_PORT=22
COPY_ERR=""         # output of the last failed copy
SSH_CONF="/etc/pve-config-backup.ssh"   # saved copy target: "user@host:/dir port"
REPLY=""

# restore state
WORK=""          # temp dir of the opened archive
X=""             # extracted archive root
P=""             # $X/pmxcfs/etc-pve  (copy of /etc/pve)
F=""             # $X/files           (local files with their original paths)
I=""             # $X/info            (reference outputs)
SRC_HOST=""      # node name of the backup
CUR_HOST=""      # node name of this host
OLD_NODE=""      # node directory in the backup whose node-specific files are used
MODE=""          # dr | select | migrate | undo
ACTIONS=()
RESTORED_VMIDS=()
REBOOT_NEEDED=0
PENDING_SRC=()
PENDING_DST=()
COMMITTED=()     # files written by the last commit
CH_LABEL=()      # choice list of a component: label, default, source, target
CH_ON=()
CH_SRC=()
CH_DST=()
CH_SEL=""        # selected indices of the choice list
CREATED=()       # files this restore created (removed again by an undo)
UNDO_ARCHIVE=""  # undo point written before this restore
ARCHIVE_FILE=""  # the archive being restored
DB_BACKUP=""
START_HOST=""    # host name when the tool started (a recovery may rename the host)
JOBS_RESTORED=0  # this run wrote backup jobs (database swap or jobs.cfg)
PMXCFS_UP=1      # /etc/pve is mounted; without it only the exact recovery is possible
CHANGES=0        # changes made by this restore (files, commands); none = undo point not kept

# Local files per component. Globs are expanded at backup time.
LOCAL_APT=(/etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/keyrings /etc/apt/trusted.gpg.d
    /etc/apt/apt.conf.d /etc/apt/preferences.d /usr/share/keyrings)
# Only what a Proxmox VE host needs for its own function; general Linux administration
# (cron, sshd, time sync, own scripts, ...) is not restored, it is in the archive via /etc.
LOCAL_SYSTEM=(
    /etc/vzdump.conf                                              # vzdump defaults
    /etc/modprobe.d /etc/modules /etc/modules-load.d              # passthrough (vfio), ZFS ARC
    /etc/kernel/cmdline /etc/default/grub /etc/default/grub.d     # IOMMU and kernel options
    /etc/default/zfs
    /etc/sysctl.conf /etc/sysctl.d                                # forwarding for guest networks
    /etc/iscsi/iscsid.conf /etc/multipath.conf /etc/multipath     # storage backends
    /etc/postfix/main.cf /etc/postfix/sasl_passwd /etc/aliases /etc/mailname   # PVE notifications
    /etc/iscsi/initiatorname.iscsi                                # iSCSI identity (SAN ACLs)
    /etc/subuid /etc/subgid                                       # id ranges for container idmaps
    /etc/default/pveproxy /etc/default/pve-ha-manager             # web UI access, HA settings
    /etc/frr/frr.conf.local                                       # own FRR additions for SDN
    /root/.ssh/authorized_keys                                    # root access, cluster SSH
)

# ---------------------------------------------------------------------------
# Logging / output / error handling
# ---------------------------------------------------------------------------
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOGFILE" 2>/dev/null || true; }
say() { log "$*"; (( QUIET )) || printf '%s\n' "$*"; }
warn() { log "WARNING: $*"; printf 'Warning: %s\n' "$*" >&2; }
note() { ACTIONS+=("$*"); log "$*"; }
is_tty() { [[ -t 0 && -t 1 ]]; }

die() {
    local msg="$*"
    log "FATAL: $msg"
    if [[ -n "${IN_TUI:-}" ]] && type -P dialog >/dev/null && is_tty; then
        dialog --backtitle "$BACKTITLE" --title "Error" --msgbox "\n$msg" 14 76 2>/dev/tty || true
        clear
    fi
    printf 'Error: %s\n' "$msg" >&2
    exit 1
}

cleanup() {
    local d
    for d in "${TMPDIRS[@]}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done
    [[ -n "$PASSFILE_TMP" && -f "$PASSFILE_TMP" ]] && rm -f -- "$PASSFILE_TMP"
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

new_tmp() { # -> REPLY = fresh private temp dir, removed on exit
    local d
    d=$(mktemp -d /var/tmp/pve-config-backup.XXXXXX) || die "Cannot create a temporary directory in /var/tmp."
    chmod 700 "$d"
    TMPDIRS+=("$d")
    REPLY=$d
}

take_lock() {
    exec 9>"$LOCK_FILE" || die "Cannot open lock file $LOCK_FILE."
    flock -n 9 || die "Another $PROG run is active (lock $LOCK_FILE)."
}

# ---------------------------------------------------------------------------
# dialog wrappers (return 1 on cancel/ESC)
# dialog runs with a UTF-8 locale, otherwise the editbox mangles umlauts in edited files
# ---------------------------------------------------------------------------
dialog() { LC_ALL=C.UTF-8 command dialog "$@"; }
d_msg()   { dialog --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" "${3:-14}" "${4:-76}" 2>/dev/tty || true; }
d_yesno() { dialog --backtitle "$BACKTITLE" --title "$1" --yesno "$2" "${3:-14}" "${4:-76}" 2>/dev/tty; }
d_noyes() { dialog --backtitle "$BACKTITLE" --title "$1" --defaultno --yesno "$2" "${3:-14}" "${4:-76}" 2>/dev/tty; }
d_info()  { dialog --backtitle "$BACKTITLE" --title "$1" --infobox "$2" "${3:-7}" "${4:-76}" 2>/dev/tty || true; }
d_text()  { dialog --backtitle "$BACKTITLE" --title "$1" --exit-label "Continue" --textbox "$2" 0 0 2>/dev/tty || true; }

d_menu() { # title text tag item ... -> tag
    local title=$1 text=$2; shift 2
    local n=$(( $# / 2 )) h out rc=0
    h=$(( n < 14 ? n : 14 )); (( h < 1 )) && h=1
    out=$(dialog --backtitle "$BACKTITLE" --title "$title" --menu "$text" $((h+10)) 78 "$h" "$@" 3>&1 1>&2 2>&3) || rc=$?
    (( rc == 0 )) || return 1
    printf '%s' "$out"
}

d_check() { # title text tag item on|off ... -> selected tags, one per line
    local title=$1 text=$2; shift 2
    local n=$(( $# / 3 )) h out rc=0
    h=$(( n < 14 ? n : 14 )); (( h < 1 )) && h=1
    local notags=()
    [[ "${1:-}" =~ ^[0-9]+$ ]] && notags=(--no-tags)
    out=$(dialog --backtitle "$BACKTITLE" --title "$title" "${notags[@]}" --separate-output --checklist "$text" $((h+10)) 78 "$h" "$@" 3>&1 1>&2 2>&3) || rc=$?
    (( rc == 0 )) || return 1
    printf '%s\n' "$out"
}

d_input() { # title text default -> value
    local out rc=0
    out=$(dialog --backtitle "$BACKTITLE" --title "$1" --inputbox "$2" 11 76 "${3:-}" 3>&1 1>&2 2>&3) || rc=$?
    (( rc == 0 )) || return 1
    printf '%s' "$out"
}

d_pass() { # title text -> value
    local out rc=0
    out=$(dialog --backtitle "$BACKTITLE" --title "$1" --insecure --passwordbox "$2" 10 76 3>&1 1>&2 2>&3) || rc=$?
    (( rc == 0 )) || return 1
    printf '%s' "$out"
}

d_edit() { # title file -> writes edited content back to file
    local title=$1 f=$2 out rc=0
    out="$f.edit"
    dialog --backtitle "$BACKTITLE" --title "$title" --output-fd 3 --editbox "$f" 0 0 3>"$out" 2>/dev/tty || rc=$?
    (( rc == 0 )) || { rm -f "$out"; return 1; }
    [[ -s "$out" && $(tail -c1 "$out" | od -An -c | tr -d ' ') != '\n' ]] && echo >>"$out"
    mv "$out" "$f"
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
# apt without any question: output goes to the log, a debconf prompt would hang invisibly
apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold "$@" </dev/null
}
# need_cmds cmd:pkg ...  -> installs missing packages after confirmation (TTY only)
need_cmds() {
    local spec cmd pkg missing=() pkgs=()
    for spec in "$@"; do
        cmd=${spec%%:*}; pkg=${spec#*:}
        type -P "$cmd" >/dev/null 2>&1 && continue
        missing+=("$cmd"); pkgs+=("$pkg")
    done
    (( ${#missing[@]} )) || return 0
    is_tty || die "Missing tools: ${missing[*]}. Install with: apt install ${pkgs[*]}"
    local ans=""
    if type -P dialog >/dev/null 2>&1; then
        d_yesno "Missing tools" "These tools are needed but not installed:\n\n  ${missing[*]}\n\nInstall the packages now?\n\n  apt install ${pkgs[*]}" 14 76 && ans=y
    else
        read -rp "Missing tools: ${missing[*]}. Install packages '${pkgs[*]}' now? [y/N] " ans
    fi
    [[ "$ans" == [yY]* ]] || die "Missing tools: ${missing[*]}. Install with: apt install ${pkgs[*]}"
    say "Installing ${pkgs[*]} ..."
    apt_install "${pkgs[@]}" >>"$LOGFILE" 2>&1 || die "apt install ${pkgs[*]} failed, see $LOGFILE."
    for cmd in "${missing[@]}"; do type -P "$cmd" >/dev/null 2>&1 || die "$cmd still missing after install."; done
}

preflight() {
    [[ $EUID -eq 0 ]] || die "Must run as root."
    command -v pveversion >/dev/null 2>&1 || die "pveversion not found. This must run on a Proxmox VE host."
    touch "$LOGFILE" 2>/dev/null && chmod 600 "$LOGFILE" 2>/dev/null
    CUR_HOST=$(hostname -s)
    START_HOST=$CUR_HOST
}

# true when the directory (or, if it does not exist yet, its nearest existing parent) is on "/"
on_root_fs() {
    local d=$1
    while [[ ! -e "$d" && "$d" != / ]]; do d=$(dirname "$d"); done
    [[ $(findmnt -n -o TARGET --target "$d" 2>/dev/null) == "/" ]]
}

pve_ver() { sed -n 's#^pve-manager/\([0-9]*\.[0-9]*\).*#\1#p' <<<"$1"; }   # "9.2"

# ---------------------------------------------------------------------------
# Passphrases / gpg
# ---------------------------------------------------------------------------
check_passfile() {
    local f=$1 mode owner
    [[ -f "$f" && -s "$f" ]] || die "Passphrase file $f does not exist or is empty."
    owner=$(stat -c %u "$f"); mode=$(stat -c %a "$f")
    [[ "$owner" == 0 ]] || die "Passphrase file $f must be owned by root."
    [[ "${mode: -2}" == "00" ]] || die "Passphrase file $f must not be readable by group/others (chmod 600)."
}

# Ask a new passphrase twice (TUI or plain TTY); REPLY = temp file holding it
ask_new_passphrase() {
    local a b
    while :; do
        if [[ -n "${IN_TUI:-}" ]]; then
            a=$(d_pass "Passphrase" "Passphrase for the backup (min. 8 characters):") || return 1
            b=$(d_pass "Passphrase" "Repeat the passphrase:") || return 1
        else
            [[ -t 0 ]] || die "--encrypt without --passphrase-file needs a terminal."
            read -rsp "Passphrase (min. 8 characters): " a; echo >&2
            read -rsp "Repeat passphrase: " b; echo >&2
        fi
        if [[ "$a" != "$b" ]]; then
            [[ -n "${IN_TUI:-}" ]] && d_msg "Passphrase" "The passphrases do not match." 7 50 || echo "Passphrases do not match." >&2
            continue
        fi
        if (( ${#a} < 8 )); then
            [[ -n "${IN_TUI:-}" ]] && d_msg "Passphrase" "Too short (min. 8 characters)." 7 50 || echo "Too short." >&2
            continue
        fi
        break
    done
    [[ -n "$PASSFILE_TMP" ]] && rm -f -- "$PASSFILE_TMP"
    PASSFILE_TMP=$(mktemp /run/pve-config-backup.pass.XXXXXX) || die "Cannot create temp file in /run."
    printf '%s' "$a" >"$PASSFILE_TMP"
    REPLY=$PASSFILE_TMP
}

ask_passphrase_once() {
    local a
    if [[ -n "${IN_TUI:-}" ]]; then
        a=$(d_pass "Encrypted backup" "Passphrase of the backup:") || return 1
    else
        [[ -t 0 ]] || die "Encrypted backup: pass --passphrase-file."
        read -rsp "Passphrase: " a; echo >&2
    fi
    [[ -n "$PASSFILE_TMP" ]] && rm -f -- "$PASSFILE_TMP"
    PASSFILE_TMP=$(mktemp /run/pve-config-backup.pass.XXXXXX) || die "Cannot create temp file in /run."
    printf '%s' "$a" >"$PASSFILE_TMP"
    REPLY=$PASSFILE_TMP
}

gpg_run() { # gpg with a throw-away home, never touches /root/.gnupg
    local gh=$1; shift
    GNUPGHOME="$gh" gpg --batch --yes --quiet --no-tty --pinentry-mode loopback "$@"
}

# ===========================================================================
# BACKUP
# ===========================================================================
collect_info() {
    local d=$1 n name mac drv pci
    run_info() { local out=$1; shift; timeout 60 "$@" >"$d/$out" 2>&1 || true; }
    run_info pveversion.txt pveversion -v
    run_info ip-addr.json ip -j addr
    run_info ip-link.json ip -j link
    run_info ip-route.txt ip route
    run_info lsblk.json lsblk -J -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,UUID
    run_info df.txt df -hT
    run_info cmdline.txt cat /proc/cmdline
    run_info uname.txt uname -a
    run_info apt-manual.txt apt-mark showmanual
    command -v lspci   >/dev/null && run_info lspci.txt lspci -nn
    command -v zpool   >/dev/null && { run_info zpool-list.txt zpool list -H -o name,size,alloc,health; run_info zpool-status.txt zpool status; run_info zfs-list.txt zfs list -o name,used,avail,mountpoint; }
    command -v vgs     >/dev/null && { run_info vgs.txt vgs; run_info lvs.txt lvs; }
    run_info pvesm-status.txt pvesm status
    run_info qm-list.txt qm list
    run_info pct-list.txt pct list
    run_info pvecm-status.txt pvecm status
    run_info ha-status.txt ha-manager status
    run_info pvereport.txt pvereport
    [[ -r $PVE_DIR/.members ]] && cp "$PVE_DIR/.members" "$d/members.json" 2>/dev/null
    [[ -r $PVE_DIR/.vmlist ]] && cp "$PVE_DIR/.vmlist" "$d/vmlist.json" 2>/dev/null
    # physical NICs: name, MAC, driver, PCI address (used for the NIC mapping on restore)
    : >"$d/nics.tsv"
    for n in /sys/class/net/*; do
        [[ -e "$n/device" ]] || continue
        name=${n##*/}
        mac=$(cat "$n/address" 2>/dev/null)
        drv=$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null)
        pci=$(basename "$(readlink -f "$n/device" 2>/dev/null)" 2>/dev/null)
        printf '%s\t%s\t%s\t%s\n' "$name" "$mac" "$drv" "$pci" >>"$d/nics.tsv"
    done
    unset -f run_info
}

# db_export_tree db dest : write the pmxcfs tree (table "tree": directories type 4, files type 8)
# as files below dest; locks are runtime state and left out
db_export_tree() {
    sqlite3 "$1" "
        WITH RECURSIVE p(inode, path, type) AS (
            SELECT inode, name, type FROM tree WHERE parent = 0 AND inode <> 0
            UNION ALL
            SELECT t.inode, p.path || '/' || t.name, t.type FROM tree t JOIN p ON t.parent = p.inode)
        SELECT writefile('$2/' || p.path,
                         CASE WHEN p.type = 4 THEN NULL ELSE coalesce(t.data, x'') END,
                         CASE WHEN p.type = 4 THEN 16832 ELSE 33152 END)   -- 040700 / 0100600
        FROM p JOIN tree t USING (inode)
        WHERE p.path <> 'priv/lock' AND p.path NOT LIKE 'priv/lock/%'
        ORDER BY p.path;" >/dev/null 2>>"$LOGFILE"
}

# own files and folders to back up: include file plus -i paths, globs expanded, existing only
extra_paths() {
    local line p
    {
        [[ -f "$INCLUDE_FILE" ]] && sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$INCLUDE_FILE"
        printf '%s\n' "${EXTRA_INCLUDES[@]}"
    } | while IFS= read -r line; do
        [[ "$line" == /* ]] || { [[ -n "$line" ]] && warn "include: '$line' is not an absolute path, skipped"; continue; }
        case "$line" in /|/etc/pve|/etc/pve/*|/proc*|/sys*|/dev*|/run*) warn "include: $line is not allowed, skipped"; continue ;; esac
        p=$(compgen -G "$line") || { log "include: $line does not exist, skipped"; continue; }
        printf '%s\n' "$p"
    done | sort -u
}

# snippet directories (cloud-init configs, hookscripts) of the directory storages
snippet_dirs() {
    [[ -f "$PVE_DIR/storage.cfg" ]] || return 0
    awk '/^[^ \t#]/ { path = ""; snip = 0 }
         $1 == "path" { path = $2 }
         $1 == "content" && $2 ~ /snippets/ { snip = 1 }
         path != "" && snip { print path "/snippets"; path = "" }' "$PVE_DIR/storage.cfg" | sort -u
}

copy_local() { # copy_local stagefiles path...
    local dst=$1 p; shift
    for p in "$@"; do
        [[ -e "$p" || -L "$p" ]] || continue
        if [[ -L "$p" && $(readlink -f "$p") == "$PVE_DIR"/* ]]; then
            cp -L --preserve=mode,ownership,timestamps --parents "$p" "$dst/" 2>>"$LOGFILE" || warn "Could not copy $p"
        else
            cp -a --parents "$p" "$dst/" 2>>"$LOGFILE" || warn "Could not copy $p"
        fi
    done
}

write_manifest() {
    local stage=$1 host=$2 fqdn pver cname="" nodes='[]' guests='[]' ip
    fqdn=$(hostname -f 2>/dev/null || echo "$host")
    pver=$(pveversion 2>/dev/null | awk 'NR==1{print $1}')
    [[ -f $PVE_DIR/corosync.conf ]] && cname=$(awk '$1=="cluster_name:"{print $2; exit}' "$PVE_DIR/corosync.conf")
    if [[ -s $stage/info/members.json ]]; then
        nodes=$(jq -c '(.nodelist // {}) | to_entries | map({name: .key, ip: .value.ip})' "$stage/info/members.json" 2>/dev/null || echo '[]')
    fi
    # guests from the exported config files (also available when pmxcfs is not mounted)
    local f
    guests=$(for f in "$stage"/pmxcfs/etc-pve/nodes/*/qemu-server/*.conf "$stage"/pmxcfs/etc-pve/nodes/*/lxc/*.conf; do
                 [[ -f "$f" ]] || continue
                 printf '%s\t%s\t%s\n' "$(basename "$f" .conf)" "$([[ $f == */lxc/* ]] && echo lxc || echo qemu)" \
                     "$(basename "$(dirname "$(dirname "$f")")")"
             done | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {vmid: .[0], type: .[1], node: .[2]})')
    ip=$(jq -r --arg h "$host" '.nodelist[$h].ip // empty' "$stage/info/members.json" 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(hostname --ip-address 2>/dev/null | awk '{print $1}')
    jq -n --arg tool "$PROG" --arg version "$VERSION" --arg created "$(date -Iseconds)" \
        --arg hostname "$host" --arg fqdn "$fqdn" --arg ip "$ip" --arg pve "$pver" \
        --arg kernel "$(uname -r)" --arg cluster "$cname" \
        --argjson nodes "$nodes" --argjson guests "$guests" \
        '{tool:$tool, tool_version:$version, created:$created, hostname:$hostname, fqdn:$fqdn,
          ip:$ip, pve_version:$pve, kernel:$kernel, cluster_name:$cluster, cluster_nodes:$nodes,
          guests:$guests}' >"$stage/manifest.json" || die "Could not write the manifest."
}

rotate_backups() { # dir host keep
    local dir=$1 host=$2 keep=$3 files=() f n
    (( keep > 0 )) || return 0
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
        | grep -E "^pvecfg_${host}_[0-9]{8}-[0-9]{6}\.tar\.zst(\.gpg)?$" | sort)
    n=${#files[@]}
    (( n > keep )) || return 0
    for f in "${files[@]:0:n-keep}"; do
        rm -f -- "${dir:?}/$f" "${dir:?}/$f.created" && log "rotated out $dir/$f"
    done
}

# do_backup outdir keep passfile(empty = unencrypted)  -> BACKUP_RESULT
do_backup() {
    local outdir=$1 keep=$2 pwfile=$3 host ts stage name out size avail
    host=$(hostname -s)
    ts=$(date +%Y%m%d-%H%M%S)
    need_cmds tar:tar zstd:zstd sqlite3:sqlite3 jq:jq
    [[ -n "$pwfile" ]] && need_cmds gpg:gpg
    [[ -f $DB ]] || die "$DB not found."

    new_tmp; stage=$REPLY
    mkdir -p "$stage/pmxcfs/etc-pve" "$stage/files" "$stage/info"

    # 1) consistent dump of the pmxcfs database, READ-ONLY: a read-write connection deletes the
    #    WAL files of the running pmxcfs when it closes, pmxcfs then writes into deleted files
    #    (later changes invisible on disk, lost on a crash)
    sqlite3 -readonly "$DB" .dump >"$stage/pmxcfs/config.dump.sql" 2>>"$LOGFILE" \
        || die "sqlite3 .dump of $DB failed."
    grep -q 'CREATE TABLE tree' "$stage/pmxcfs/config.dump.sql" || die "The config.db dump looks incomplete."

    # 2) file view of /etc/pve, built from the dump: the same state as the database and
    #    independent of the pmxcfs mount (works when pve-cluster is down)
    sqlite3 "$stage/check.db" <"$stage/pmxcfs/config.dump.sql" 2>>"$LOGFILE" || die "The config.db dump cannot be read back."
    db_export_tree "$stage/check.db" "$stage/pmxcfs/etc-pve" || die "Exporting the /etc/pve files from the database failed."
    rm -f "$stage/check.db"

    # 3) local files: all of /etc (small; restored only selectively, the rest is reference),
    #    the listed paths outside /etc and the snippet directories of the storages
    tar -C / --exclude=etc/pve -cf - etc 2>>"$LOGFILE" | tar -C "$stage/files" -xpf - 2>>"$LOGFILE" \
        || die "Copying /etc failed."
    local other=() p extra=()
    for p in /usr/local/lib/systemd/network /usr/share/keyrings /root/.ssh/authorized_keys /root/.ssh/id_* "$RRD_DIR" $(snippet_dirs); do
        [[ "$p" == /etc/* ]] || other+=("$p")
    done
    # own files and folders (paths below /etc are already in the archive)
    mapfile -t extra < <(extra_paths)
    for p in "${extra[@]}"; do [[ "$p" == /etc/* ]] || other+=("$p"); done
    copy_local "$stage/files" "${other[@]}"
    printf '%s\n' "${extra[@]}" | awk 'NF' >"$stage/info/extra.txt"

    # 4) reference information + manifest + checksums
    collect_info "$stage/info"
    write_manifest "$stage" "$host"
    ( cd "$stage" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) >"$stage.sha256" \
        && mv "$stage.sha256" "$stage/SHA256SUMS" || die "Checksum creation failed."

    # 5) target directory
    if [[ ! -d "$outdir" ]]; then
        mkdir -p "$outdir" || die "Cannot create $outdir."
        chmod 700 "$outdir"
    fi
    [[ -w "$outdir" ]] || die "$outdir is not writable."
    size=$(du -sb "$stage" | awk '{print $1}')
    avail=$(df --output=avail -B1 "$outdir" | tail -1 | tr -d ' ')
    (( avail > size )) || die "Not enough free space in $outdir ($(numfmt --to=iec "$avail") free, need up to $(numfmt --to=iec "$size"))."

    name="pvecfg_${host}_${ts}.tar.zst"
    out="$outdir/$name"
    tar -C "$stage" --zstd -cf "$out.part" . 2>>"$LOGFILE" || { rm -f "$out.part"; die "Creating the archive failed."; }
    if [[ -n "$pwfile" ]]; then
        mkdir -p "$stage/.gnupg"; chmod 700 "$stage/.gnupg"
        gpg_run "$stage/.gnupg" --symmetric --cipher-algo AES256 --passphrase-file "$pwfile" \
            -o "$out.gpg.part" "$out.part" 2>>"$LOGFILE" || { rm -f "$out.part" "$out.gpg.part"; die "Encryption failed."; }
        rm -f "$out.part"
        out="$out.gpg"
        mv "$out.part" "$out"
    else
        mv "$out.part" "$out"
    fi
    chmod 600 "$out"
    rotate_backups "$outdir" "$host" "$keep"
    on_root_fs "$outdir" \
        && log "note: $outdir is on the root filesystem; a copy elsewhere is needed to survive a host failure"
    BACKUP_RESULT=$out
    say "Backup written: $out ($(numfmt --to=iec "$(stat -c %s "$out")"))"
}

# ===========================================================================
# Copy to another host (SSH)
# The target restricts the key with rrsync to one directory: write only, no shell, no reading,
# no deleting. With rrsync the upload path is relative to that directory, so files go to "".
# ===========================================================================
valid_copy_target() { [[ "$1" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:/[A-Za-z0-9._/-]+$ ]]; }

# copy_remote file : upload to COPY_TO; 0 on success
copy_remote() {
    local f=$1 out rc=0
    [[ -f "$SSH_KEY" ]] || { warn "SSH key $SSH_KEY missing; set up the copy with '$PROG schedule'."; return 1; }
    need_cmds rsync:rsync ssh:openssh-client
    out=$(rsync -t --chmod=F600 --timeout=120 \
        -e "ssh -i $SSH_KEY -p $SSH_PORT -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20" \
        "$f" "${COPY_TO%%:*}:" 2>&1) || rc=$?
    out=${out//$'\r'/}   # ssh ends its messages with CR, which hides them in dialog
    if (( rc == 0 )); then
        say "Copied to ${COPY_TO}/$(basename "$f")"
    else
        COPY_ERR=$out
        log "copy to $COPY_TO failed (rsync $rc): $out"
        warn "Copy to $COPY_TO failed (rsync exit $rc): $(tail -1 <<<"$out")"
    fi
    return "$rc"
}

# authorized_keys line for the target
copy_key_line() { printf 'command="rrsync -wo %s",restrict %s\n' "${COPY_TO#*:}" "$(cat "$SSH_KEY.pub")"; }

# ssh_setup default_target : ask target and port, create the key, show the target setup, test;
# sets COPY_TO/SSH_PORT, returns 1 when cancelled
ssh_setup() {
    local t port new=0 txt="/root/pve-config-backup-ssh-target.txt"
    t=$(d_input "Copy via SSH" "Target as user@host:/directory. Use a dedicated user on the target that owns only this directory:" "${1:-}") || return 1
    valid_copy_target "$t" || { d_msg "Copy via SSH" "Not a valid target: '$t'\n\nExample: backup@nas.example.org:/srv/pve-config" 9 70; return 1; }
    port=$(d_input "Copy via SSH" "SSH port of $t:" "$SSH_PORT") || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || { d_msg "Copy via SSH" "Not a port number." 7 40; return 1; }
    COPY_TO=$t; SSH_PORT=$port
    need_cmds rsync:rsync ssh:openssh-client ssh-keygen:openssh-client
    if [[ ! -f "$SSH_KEY" ]]; then
        ssh-keygen -q -t ed25519 -N "" -C "pve-config-backup@$(hostname -s)" -f "$SSH_KEY" || { d_msg "Error" "ssh-keygen failed." 7 40; return 1; }
        new=1
    fi
    { echo "On ${COPY_TO%%@*}@$(sed 's/^[^@]*@//; s/:.*//' <<<"$COPY_TO"), add this ONE line to ~${COPY_TO%%@*}/.ssh/authorized_keys:"
      echo
      copy_key_line
      echo
      echo "The directory ${COPY_TO#*:} must exist and belong to that user; rsync must be installed"
      echo "there (it provides rrsync). The key can only write into that directory: no shell, no"
      echo "reading, no deleting. Old backups are cleaned up on the target, e.g. by a cron job:"
      echo "  find ${COPY_TO#*:} -name 'pvecfg_*' -mtime +60 -delete"
      echo
      echo "Keep the backup passphrase outside both hosts (password manager)."
    } >"$txt"
    chmod 600 "$txt"
    (( new )) && d_text "Copy via SSH: set up the target (also in $txt)" "$txt"
    while d_yesno "Copy via SSH" "Test the connection now? (uploads a small file .pve-config-backup-test)$( (( new )) || echo "\n\nThe target setup is in $txt.")" 10 72; do
        local tf; tf=$(mktemp -d /var/tmp/pve-config-backup.XXXXXX)/.pve-config-backup-test
        date >"$tf"
        d_info "Copy via SSH" "Connecting to $COPY_TO ..."
        if copy_remote "$tf" 2>/dev/null >/dev/null; then
            rm -rf -- "$(dirname "$tf")"
            d_msg "Copy via SSH" "Upload to $COPY_TO works." 7 60
            return 0
        fi
        rm -rf -- "$(dirname "$tf")"
        { echo "The test upload failed:"; echo; echo "$COPY_ERR"; echo; cat "$txt"; } >"$txt.err"
        d_text "Copy via SSH: test failed" "$txt.err"; rm -f "$txt.err"
    done
    return 0
}

# saved_target -> "target port": the scheduled job's target, else the saved one
saved_target() {
    local t p
    t=$(cron_line | sed -nE 's/.* --copy-to ([^ ]+).*/\1/p')
    p=$(cron_line | sed -nE 's/.* --ssh-port ([0-9]+).*/\1/p')
    if [[ -z "$t" && -f "$SSH_CONF" ]]; then read -r t p <"$SSH_CONF"; fi
    [[ -n "$t" ]] && echo "$t ${p:-22}"
}

# write COPY_TO/SSH_PORT into the cron job (or remove the copy with an empty COPY_TO)
cron_set_copy() {
    local line pw
    line=$(cron_line); [[ -n "$line" ]] || return 1
    line=$(sed -E 's/ --copy-to [^ ]+//; s/ --ssh-port [0-9]+//; s/ --copy-unencrypted//' <<<"$line")
    if [[ -n "$COPY_TO" ]]; then
        pw=" --copy-to $COPY_TO"; (( SSH_PORT != 22 )) && pw+=" --ssh-port $SSH_PORT"
        [[ "$line" == *" -p "* ]] || pw+=" --copy-unencrypted"
        line=$(sed -E "s# -q\$#$pw -q#" <<<"$line")
    fi
    sed -i "\#^[^#].* root #c\\$line" "$CRON_FILE" && log "schedule copy target: ${COPY_TO:-none}"
}

ssh_menu() {
    local c cur t p
    while :; do
        cur=$(saved_target); read -r t p <<<"$cur"
        c=$(d_menu "Copy via SSH" "Copy backups to another host, so they survive a failure of this one.\n\nTarget: ${t:-none}${t:+ (port $p)}\nScheduled backup: $(cron_line | grep -q -- '--copy-to' && echo 'copies' || echo 'does not copy')" \
            setup "set up / change the target (key, target setup, test)" \
            show "show the line for authorized_keys on the target" \
            test "test the connection" \
            schedule "copy with the scheduled backup: on / off" \
            back "back") || return 0
        case "$c" in
            setup)
                SSH_PORT=${p:-22}
                ssh_setup "$t" || continue
                printf '%s %s\n' "$COPY_TO" "$SSH_PORT" >"$SSH_CONF"; chmod 600 "$SSH_CONF"
                if cron_line | grep -q -- '--copy-to'; then cron_set_copy && d_msg "Copy via SSH" "The scheduled backup copies to $COPY_TO from now on." 8 72; fi ;;
            show)
                [[ -n "$t" && -f "$SSH_KEY.pub" ]] || { d_msg "Copy via SSH" "No target set up yet." 7 50; continue; }
                COPY_TO=$t; SSH_PORT=$p
                { echo "Add this ONE line to ~${t%%@*}/.ssh/authorized_keys on the target:"; echo; copy_key_line; } >"/root/pve-config-backup-ssh-target.txt"
                d_text "authorized_keys line (also in /root/pve-config-backup-ssh-target.txt)" /root/pve-config-backup-ssh-target.txt ;;
            test)
                [[ -n "$t" ]] || { d_msg "Copy via SSH" "No target set up yet." 7 50; continue; }
                COPY_TO=$t; SSH_PORT=$p
                local tf; tf=$(mktemp -d /var/tmp/pve-config-backup.XXXXXX)/.pve-config-backup-test; date >"$tf"
                d_info "Copy via SSH" "Connecting to $t ..."
                if copy_remote "$tf" >/dev/null 2>&1; then d_msg "Copy via SSH" "Upload to $t works." 7 60
                else d_msg "Copy via SSH" "The test upload failed:\n\n${COPY_ERR//$'\n'/\\n}" 14 76; fi
                rm -rf -- "$(dirname "$tf")" ;;
            schedule)
                [[ -n "$(cron_line)" ]] || { d_msg "Copy via SSH" "No scheduled backup yet: set it up under 'schedule' first." 8 60; continue; }
                if cron_line | grep -q -- '--copy-to'; then
                    d_yesno "Copy via SSH" "Stop copying with the scheduled backup?" 7 60 && { COPY_TO=""; cron_set_copy; }
                else
                    [[ -n "$t" ]] || { d_msg "Copy via SSH" "Set up a target first." 7 50; continue; }
                    if ! cron_line | grep -q -- ' -p '; then
                        d_noyes "Copy via SSH" "The scheduled backups are NOT encrypted, but they hold passwords, token secrets and keys.\n\nCopy them unencrypted anyway?" 11 72 || continue
                    fi
                    COPY_TO=$t; SSH_PORT=$p; cron_set_copy && d_msg "Copy via SSH" "The scheduled backup copies to $t from now on." 8 72
                fi ;;
            back) return 0 ;;
        esac
    done
}

cmd_backup() {
    local outdir=$DEFAULT_DIR keep=$DEFAULT_KEEP enc=0 pwfile="" plain=0
    while (( $# )); do
        case "$1" in
            -o|--output) outdir=${2:?missing directory}; shift 2 ;;
            -k|--keep) keep=${2:?missing number}; shift 2 ;;
            -e|--encrypt) enc=1; shift ;;
            -p|--passphrase-file) pwfile=${2:?missing file}; enc=1; shift 2 ;;
            -i|--include) EXTRA_INCLUDES+=("${2:?missing path}"); shift 2 ;;
            --copy-to) COPY_TO=${2:?missing target}; shift 2 ;;
            --ssh-port) SSH_PORT=${2:?missing port}; shift 2 ;;
            --copy-unencrypted) plain=1; shift ;;
            -q|--quiet) QUIET=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option for backup: $1" ;;
        esac
    done
    [[ "$keep" =~ ^[0-9]+$ ]] || die "--keep needs a number."
    [[ -z "$COPY_TO" ]] || valid_copy_target "$COPY_TO" || die "--copy-to needs user@host:/directory."
    [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "--ssh-port needs a number."
    [[ -n "$COPY_TO" ]] && (( ! enc && ! plain )) \
        && die "Refusing to copy an unencrypted backup (it holds passwords and keys): add -p FILE, or --copy-unencrypted."
    preflight
    take_lock
    if (( enc )); then
        if [[ -n "$pwfile" ]]; then check_passfile "$pwfile"
        else ask_new_passphrase; pwfile=$REPLY; fi
    fi
    do_backup "$outdir" "$keep" "$pwfile"
    # the local backup is written; a failed copy is reported with exit code 3 (cron mails it)
    [[ -z "$COPY_TO" ]] || copy_remote "$BACKUP_RESULT" || exit 3
}

# ===========================================================================
# ARCHIVE HANDLING (restore / inspect)
# ===========================================================================
open_archive() { # file [passfile]
    local file=$1 pwfile=${2:-} tarball
    [[ -f "$file" ]] || die "$file not found."
    need_cmds tar:tar zstd:zstd jq:jq
    new_tmp; WORK=$REPLY
    X="$WORK/x"; mkdir -p "$X"
    tarball=$file
    if [[ "$file" == *.gpg ]]; then
        need_cmds gpg:gpg
        mkdir -p "$WORK/.gnupg"; chmod 700 "$WORK/.gnupg"
        local try ok=0
        for try in 1 2 3; do   # a passphrase file is used once, a typed passphrase may be retried
            if [[ -z "$pwfile" || "$try" -gt 1 ]]; then
                [[ -n "$pwfile" && "$pwfile" != "$PASSFILE_TMP" ]] && break
                ask_passphrase_once || die "Cancelled."; pwfile=$REPLY
            fi
            if gpg_run "$WORK/.gnupg" --decrypt --passphrase-file "$pwfile" -o "$WORK/archive.tar.zst" "$file" 2>>"$LOGFILE"; then
                ok=1; break
            fi
            if [[ "$pwfile" == "$PASSFILE_TMP" ]]; then
                if [[ -n "${IN_TUI:-}" ]]; then d_msg "Encrypted backup" "Wrong passphrase (attempt $try of 3)." 7 50
                else echo "Wrong passphrase (attempt $try of 3)." >&2; fi
            fi
        done
        (( ok )) || die "Decryption failed (wrong passphrase or damaged file)."
        tarball="$WORK/archive.tar.zst"
    fi
    tar -C "$X" --zstd -xpf "$tarball" 2>>"$LOGFILE" || die "Extracting $file failed."
    [[ -f "$X/manifest.json" && -f "$X/SHA256SUMS" ]] || die "$file is not a $PROG archive."
    ( cd "$X" && sha256sum -c --quiet SHA256SUMS ) >>"$LOGFILE" 2>&1 || die "Checksum verification failed, the archive is damaged."
    P="$X/pmxcfs/etc-pve"; F="$X/files"; I="$X/info"
    SRC_HOST=$(jq -r .hostname "$X/manifest.json")
}

m() { jq -r "$1" "$X/manifest.json"; }

# vmid -> "VM"/"CT" name node conf-path, from the archive
guest_confs() { # prints: vmid<TAB>type<TAB>node<TAB>name<TAB>relpath
    local f vmid type node name
    [[ -d "$P/nodes" ]] || return 0
    for f in "$P"/nodes/*/qemu-server/*.conf "$P"/nodes/*/lxc/*.conf; do
        [[ -f "$f" ]] || continue
        vmid=$(basename "$f" .conf)
        node=$(basename "$(dirname "$(dirname "$f")")")
        if [[ "$f" == */lxc/* ]]; then
            type=CT; name=$(awk -F': ' '/^\[/{exit} $1=="hostname"{print $2; exit}' "$f")
        else
            type=VM; name=$(awk -F': ' '/^\[/{exit} $1=="name"{print $2; exit}' "$f")
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$vmid" "$type" "$node" "${name:--}" "${f#"$P"/}"
    done | sort -n
}

inspect_text() {
    local out=$1 p
    {
        echo "Tool version : $(m .tool_version)"
        echo "Created      : $(m .created)"
        echo "Source host  : $(m .hostname) ($(m .fqdn)), IP $(m .ip)"
        echo "PVE          : $(m .pve_version)"
        echo "Kernel       : $(m .kernel)"
        if [[ -n "$(m .cluster_name)" ]]; then
            echo "Cluster      : $(m .cluster_name), nodes: $(m '[.cluster_nodes[] | .name + " (" + .ip + ")"] | join(", ")')"
        else
            echo "Cluster      : none (standalone)"
        fi
        echo
        echo "Storages:"
        sc_ids "$P/storage.cfg" | sed 's/^/  /'
        echo
        echo "Users / tokens / groups / ACLs:"
        [[ -f "$P/user.cfg" ]] && awk -F: 'NF>1{c[$1]++} END{for(k in c) printf "  %-6s %d\n", k, c[k]}' "$P/user.cfg" | sort
        echo
        echo "Guests (configs only, disks come from PBS):"
        guest_confs | awk -F'\t' '{printf "  %-5s %-6s %-12s %s\n", $2, $1, $3, $4}'
        echo
        echo "Physical NICs:"
        [[ -f "$I/nics.tsv" ]] && awk -F'\t' '{printf "  %-12s %s  %s  %s\n", $1, $2, $3, $4}' "$I/nics.tsv"
        echo
        echo "Other pmxcfs content:"
        local f
        for f in datacenter.cfg jobs.cfg vzdump.cron replication.cfg notifications.cfg status.cfg \
                 virtual-guest/cpu-models.conf firewall/cluster.fw domains.cfg ceph.conf corosync.conf; do
            [[ -f "$P/$f" ]] && echo "  $f"
        done
        for f in sdn mapping ha priv/acme; do
            [[ -d "$P/$f" ]] && [[ -n "$(ls -A "$P/$f" 2>/dev/null)" ]] && echo "  $f/ ($(ls -A "$P/$f" | tr '\n' ' '))"
        done
        [[ -f "$P/ceph.conf" ]] && echo "  NOTE: Ceph is configured; Ceph is not restored by this tool."
        echo
        if [[ -s "$I/extra.txt" ]]; then
            echo "Own files and folders (include list):"
            while IFS= read -r p; do
                printf '  %-60s %s\n' "$p" "$(du -sh "$F$p" 2>/dev/null | cut -f1)"
            done <"$I/extra.txt"
            echo
        fi
        echo "Local files:"
        echo "  /etc ($(find "$F/etc" \( -type f -o -type l \) 2>/dev/null | wc -l) files, without /etc/pve)"
        ( cd "$F" 2>/dev/null && find . -mindepth 1 \( -type f -o -type l \) -not -path './etc/*' -not -path './var/lib/rrdcached/*' -printf '%P\n' ) \
            | sed 's#^#  /#' | sort | head -200
        [[ -d "$F$RRD_DIR" ]] && echo "  $RRD_DIR (statistics)"
    } >"$out"
}

# What a restore cannot bring back, in general and per mode
not_restorable() { # mode -> text
    cat <<'EOF2'
Never restored by this tool:
  - guest disks and container volumes: restore those from Proxmox Backup Server
  - Ceph (its configuration is kept for reference only)
  - the root password and other local Linux users (/etc/shadow is in the archive for
    reference only)
  - installed packages, kernel and bootloader (missing packages are only listed)
  - disk, ZFS pool and LVM layout: existing pools are imported, nothing is created
  - general Linux administration: cron, sshd config, time sync, own scripts, fstab, ...;
    only Proxmox VE parts are offered, all of /etc is in the archive for manual extraction
EOF2
    case "${1:-}" in
        dr) cat <<'EOF2'

Full disaster recovery, exact:
  - /etc/pve is replaced completely; changes made on this host since its installation are lost
  - hardware-bound settings (NIC names, PCI/USB mappings, passthrough) must match the new hardware
  - a former cluster member comes back alone and waits for quorum ('pvecm expected 1')
EOF2
        ;;
        migrate) cat <<'EOF2'

Selective migration (other node name):
  - node identity is never copied: node certificate, cluster CA, auth keys, cluster SSH keys
  - corosync configuration and keys, HA runtime state, locks
  - resource mappings and passthrough point at the old hardware and need checking
EOF2
        ;;
        select) cat <<'EOF2'

Selective restore (same node name):
  - entries are added or replaced, nothing that exists only on this host is deleted
    (use the exact restore for an identical /etc/pve)
EOF2
        ;;
    esac
}

cmd_inspect() {
    local file="" pwfile=""
    while (( $# )); do
        case "$1" in
            -p|--passphrase-file) pwfile=${2:?}; shift 2 ;;
            *) file=$1; shift ;;
        esac
    done
    [[ -n "$file" ]] || die "Usage: $PROG inspect FILE"
    preflight
    [[ -n "$pwfile" ]] && check_passfile "$pwfile"
    open_archive "$file" "$pwfile"
    inspect_text "$WORK/inspect.txt"
    { echo; not_restorable; } >>"$WORK/inspect.txt"
    if [[ -n "${IN_TUI:-}" ]]; then d_text "Backup contents: $(basename "$file")" "$WORK/inspect.txt"
    else cat "$WORK/inspect.txt"; fi
}

# ===========================================================================
# Section-config helpers (storage.cfg, domains.cfg, ha/*.cfg, sdn, mapping/*.cfg, ...)
# A section starts at a line in column 0, either "type: id" or only "id" (mapping/*.cfg);
# its properties are indented.
# ===========================================================================
SC_HEAD='/^[^ \t#]/ { id = ($1 ~ /:$/) ? $2 : $1 }'
sc_ids() { # file -> "type: id" (or "id: id") per section
    [[ -f "$1" ]] || return 0
    awk '/^[^ \t#]/ { if ($1 ~ /:$/) print $1 " " $2; else print $1 ": " $1 }' "$1"
}
sc_get() { # file id -> section block
    awk -v want="$2" "$SC_HEAD"' { p = (id == want) } p' "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}
# sc_merge current backup out id... : the sections of ids are taken from the backup, in place
# where they exist here, appended otherwise; an unchanged selection gives an identical file
sc_merge() {
    local cur=$1 bak=$2 out=$3 id sep=""; shift 3
    local -A pending=()
    for id in "$@"; do pending[$id]=1; done
    {
        [[ -f "$cur" ]] && awk '/^[^ \t#]/ { exit } { print }' "$cur"   # lines before the first section
        for id in $(sc_ids "$cur" | awk '{print $2}'); do
            printf '%s' "$sep"; sep=$'\n'
            if [[ -n "${pending[$id]:-}" ]]; then sc_get "$bak" "$id"; pending[$id]=""; else sc_get "$cur" "$id"; fi
        done
        for id in "$@"; do
            [[ -n "${pending[$id]}" ]] || continue
            printf '%s' "$sep"; sep=$'\n'
            sc_get "$bak" "$id"
        done
        # keep the file ending (PVE writes some section files with a trailing empty line)
        local ref=$cur; [[ -f "$ref" ]] || ref=$bak
        [[ -f "$ref" && -z "$(tail -n1 "$ref")" ]] && echo
    } >"$out"
}

# Rewrite node references OLD_NODE -> CUR_HOST in a config file: "nodes"/"target" properties
# (comma lists, optional ":priority") and "node=" values. Only these, never free text.
rename_nodes() {
    [[ "$OLD_NODE" != "$CUR_HOST" && -f "$1" ]] || return 0
    awk -v o="$OLD_NODE" -v n="$CUR_HOST" '
        /^[ \t]+(nodes|target)[ \t]/ {
            c = split($2, a, ","); out = ""
            for (i = 1; i <= c; i++) {
                split(a[i], b, ":"); if (b[1] == o) a[i] = n substr(a[i], length(o) + 1)
                out = out (i > 1 ? "," : "") a[i]
            }
            print "\t" $1 " " out; next
        }
        { gsub("node=" o ",", "node=" n ","); sub("node=" o "$", "node=" n); print }' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

# ===========================================================================
# Staged writes with review
# ===========================================================================
stage() { PENDING_SRC+=("$1"); PENDING_DST+=("$2"); }

# make_parents path : create the missing parent directories of path, with mode and owner of the
# same directory in the archive, 755 root otherwise (the script's umask 077 would give 700)
make_parents() {
    local d missing=()
    d=$(dirname "$1")
    while [[ ! -d "$d" ]]; do missing=("$d" "${missing[@]}"); d=$(dirname "$d"); done
    for d in "${missing[@]}"; do
        if [[ "$d" != "$PVE_DIR"/* && -d "$F$d" ]]; then
            mkdir "$d" && chmod --reference="$F$d" "$d" && chown --reference="$F$d" "$d"
        else
            mkdir -m 755 "$d"
        fi
    done 2>>"$LOGFILE"
}

put_file() { # src dst
    local src=$1 dst=$2
    if [[ -e "$dst" ]] && cmp -s "$src" "$dst"; then return 0; fi
    if (( DRY_RUN )); then note "[dry-run] would write $dst"; return 0; fi
    local existed=1
    [[ -e "$dst" || -L "$dst" ]] || existed=0
    make_parents "$dst"
    # pmxcfs has no modes/owners; existing local files keep their mode/owner (content only);
    # new local files and symlinks come with the mode/owner stored in the archive
    if [[ -L "$src" && "$dst" != "$PVE_DIR"/* ]]; then
        cp -a --remove-destination "$src" "$dst" 2>>"$LOGFILE"
    elif [[ "$dst" == "$PVE_DIR"/* || -e "$dst" ]]; then
        cat "$src" >"$dst" 2>>"$LOGFILE"
    else
        cp -a "$src" "$dst" 2>>"$LOGFILE"
    fi || { note "FAILED to write $dst"; return 1; }
    [[ "$existed" == 0 ]] && CREATED+=("$dst")
    CHANGES=$((CHANGES+1))
    note "written: $dst"
}

# files whose content is never shown in the diff
is_secret() {
    case "$1" in
        "$PVE_DIR"/priv/*|"$PVE_DIR"/domains.cfg|"$PVE_DIR"/nodes/*/*.key|*/ssh_host_*key|*sasl_passwd|/etc/shadow*) return 0 ;;
        */.ssh/id_*.pub) return 1 ;;
        */.ssh/id_*) return 0 ;;
    esac
    return 1
}

# commit title -> shows the combined diff, asks, writes. Returns 1 when declined.
commit() {
    local title=$1 i s d n=0 df="$WORK/diff.txt"
    : >"$df"
    for i in "${!PENDING_SRC[@]}"; do
        s=${PENDING_SRC[$i]}; d=${PENDING_DST[$i]}
        [[ -e "$d" ]] && cmp -s "$s" "$d" && continue
        n=$((n+1))
        if is_secret "$d"; then
            printf '=== %s: secret file, content hidden (%s)\n\n' "$d" "$([[ -e $d ]] && echo changed || echo new)" >>"$df"
        else
            printf '=== %s (%s)\n' "$d" "$([[ -e $d ]] && echo changed || echo new)" >>"$df"
            diff -u --label "current" --label "from backup" "$([[ -e $d ]] && echo "$d" || echo /dev/null)" "$s" >>"$df" 2>&1
            echo >>"$df"
        fi
    done
    COMMITTED=()
    if (( n == 0 )); then
        note "$title: nothing to change"
        PENDING_SRC=(); PENDING_DST=()
        return 0
    fi
    d_text "$title: $n file(s) will change" "$df"
    if ! d_yesno "$title" "Apply these $n change(s)?$( (( DRY_RUN )) && echo '\n\n(dry run: nothing is written)')" 9 60; then
        note "$title: skipped by user"
        PENDING_SRC=(); PENDING_DST=()
        return 1
    fi
    for i in "${!PENDING_SRC[@]}"; do
        s=${PENDING_SRC[$i]}; d=${PENDING_DST[$i]}
        [[ -e "$d" ]] && cmp -s "$s" "$d" && continue      # unchanged: nothing to write or follow up
        put_file "$s" "$d" && COMMITTED+=("$d")
    done
    PENDING_SRC=(); PENDING_DST=()
    return 0
}

run_cmd() { # command... (logged; skipped in dry run)
    if (( DRY_RUN )); then note "[dry-run] would run: $*"; return 0; fi
    log "run: $*"
    if "$@" >>"$LOGFILE" 2>&1; then CHANGES=$((CHANGES+1)); note "ran: $*"; return 0; fi
    note "FAILED: $* (see $LOGFILE)"
    return 1
}

# ===========================================================================
# Choice list: every component offers entries (label, default, source, target), the user
# picks, the picked entries are staged and committed with a diff review.
# ===========================================================================
ch_reset() { CH_LABEL=(); CH_ON=(); CH_SRC=(); CH_DST=(); CH_SEL=""; }
ch_add()   { CH_LABEL+=("$1"); CH_ON+=("$2"); CH_SRC+=("$3"); CH_DST+=("$4"); }

ch_pick() { # title text -> CH_SEL; returns 1 when nothing is offered or on cancel
    local i items=()
    (( ${#CH_LABEL[@]} )) || { note "$1: nothing to restore"; return 1; }
    for i in "${!CH_LABEL[@]}"; do items+=("$i" "${CH_LABEL[$i]}" "${CH_ON[$i]}"); done
    CH_SEL=$(d_check "$1" "$2" "${items[@]}") || return 1
}

ch_stage() { local i; for i in $CH_SEL; do stage_path "${CH_SRC[$i]}" "${CH_DST[$i]}"; done; }

# stage one file, or every file below a directory (merged: nothing is deleted)
stage_path() {
    local src=$1 dst=$2 f
    if [[ "$dst" == /etc/subuid || "$dst" == /etc/subgid ]]; then
        # id ranges are added, never replaced (other ranges of this host stay)
        local add
        if [[ -f "$dst" ]]; then add=$(grep -vxF -f "$dst" "$src" | awk 'NF'); else add=$(awk 'NF' "$src"); fi
        [[ -n "$add" ]] || return 0
        { cat "$dst" 2>/dev/null; printf '%s\n' "$add"; } >"$WORK/${dst##*/}.new"
        stage "$WORK/${dst##*/}.new" "$dst"
    elif [[ "$dst" == /root/.ssh/authorized_keys ]]; then
        # keys are added, never replaced; nothing to do when every key is already there
        local new
        if [[ -f "$dst" ]]; then new=$(grep -vxF -f "$dst" "$src" | awk 'NF'); else new=$(awk 'NF' "$src"); fi
        [[ -n "$new" ]] || return 0
        { cat "$dst" 2>/dev/null; printf '%s\n' "$new"; } >"$WORK/authorized_keys.new"
        stage "$WORK/authorized_keys.new" "$dst"
    elif [[ -d "$src" && ! -L "$src" ]]; then
        while IFS= read -r -d '' f; do
            # package keyrings: only add missing ones, never downgrade a packaged key
            [[ "$dst" == /usr/share/keyrings && -e "$dst/$f" ]] && continue
            stage "$src/$f" "$dst/$f"
        done < <(cd "$src" && find . \( -type f -o -type l \) -printf '%P\0')
    else
        stage "$src" "$dst"
    fi
}

# ===========================================================================
# Restore components: local files
# ===========================================================================
local_component() { # title default(on|off) path...
    local title=$1 def=$2 p; shift 2
    local on label
    ch_reset
    for p in "$@"; do
        [[ -e "$F$p" || -L "$F$p" ]] || continue
        on=$def; label=$p
        case "$p" in
            # boot and driver settings belong to the hardware: off when moving to another host
            /etc/kernel/cmdline|/etc/default/grub|/etc/default/grub.d|/etc/modprobe.d|/etc/modules|/etc/modules-load.d)
                [[ "$MODE" == migrate ]] && { on=off; label+="  (hardware/boot)"; } ;;
            # two hosts with the same IQN break iSCSI sessions
            /etc/iscsi/initiatorname.iscsi)
                [[ "$MODE" == migrate ]] && { on=off; label+="  (host identity)"; } ;;
        esac
        # a different root= makes the host unbootable
        if [[ "$p" == /etc/kernel/cmdline ]] && [[ "$(grep -o 'root=[^ ]*' "$F$p")" != "$(grep -o 'root=[^ ]*' "$p" 2>/dev/null)" ]]; then
            on=off; label+="  [root= differs]"
        fi
        ch_add "$label" "$on" "$F$p" "$p"
    done
    ch_pick "$title" "Select what to restore (directories are merged: files are added/overwritten, nothing is deleted):" || return 0
    ch_stage
    commit "$title" && post_hooks
}

# follow-up commands for the files the last commit wrote
post_hooks() {
    local f boot=0 initrd=0 sysctl=0 ssh=0 postfix=0
    for f in "${COMMITTED[@]}"; do
        case "$f" in
            /etc/kernel/cmdline|/etc/default/grub|/etc/default/grub.d/*) boot=1 ;;
            /etc/modprobe.d/*|/etc/modules|/etc/modules-load.d/*|/etc/systemd/network/*|/usr/local/lib/systemd/network/*) initrd=1 ;;
            /etc/sysctl.conf|/etc/sysctl.d/*) sysctl=1 ;;
            /etc/ssh/ssh_host_*) ssh=1 ;;
            /etc/postfix/*|/etc/mailname|/etc/aliases) postfix=1 ;;
        esac
    done
    (( initrd || boot )) && d_info "Applying" "Updating initramfs and boot configuration ..."
    if (( initrd )); then run_cmd update-initramfs -u -k all; REBOOT_NEEDED=1; fi
    if (( boot )); then
        if [[ -f /etc/kernel/proxmox-boot-uuids ]]; then run_cmd proxmox-boot-tool refresh; else run_cmd update-grub; fi
        REBOOT_NEEDED=1
    fi
    (( sysctl )) && run_cmd sysctl --system
    (( ssh )) && run_cmd systemctl reload-or-restart ssh
    if (( postfix )); then
        [[ -f /etc/postfix/sasl_passwd ]] && run_cmd postmap /etc/postfix/sasl_passwd
        command -v newaliases >/dev/null && run_cmd newaliases
        run_cmd systemctl reload-or-restart postfix
    fi
    return 0
}

restore_apt() {
    local before after
    before=$(find /etc/apt -type f -printf '%P %s %T@\n' 2>/dev/null | sort | md5sum)
    local_component "APT sources" on "${LOCAL_APT[@]}"
    after=$(find /etc/apt -type f -printf '%P %s %T@\n' 2>/dev/null | sort | md5sum)
    # repositories of this installation that the source host did not have (e.g. the enterprise
    # repos of a fresh install without subscription): merging never deletes, so offer to disable
    if [[ -d "$F/etc/apt/sources.list.d" ]]; then
        local f items=() extra=() idx=0
        for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [[ -f "$f" ]] || continue
            [[ -e "$F$f" ]] && continue
            extra+=("$f"); items+=("$idx" "${f##*/}" on); idx=$((idx+1))
        done
        if (( ${#items[@]} )); then
            local sel s
            sel=$(d_check "APT sources" "These repositories exist here but not on $SRC_HOST. Disable them (renamed to *.disabled)?" "${items[@]}") || sel=""
            for s in $sel; do
                run_cmd mv "${extra[$s]}" "${extra[$s]}.disabled" && { (( DRY_RUN )) || CREATED+=("${extra[$s]}.disabled"); }
                after=changed
            done
        fi
    fi
    if [[ "$before" != "$after" ]]; then
        # without name resolution apt waits for every repository in turn (minutes)
        local repo
        repo=$(grep -rhE --include='*.sources' --include='*.list' '^[[:space:]]*(URIs:|deb[[:space:]])' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
            | grep -oE 'https?://[^/[:space:]]+' | head -1)
        repo=${repo#*://}
        if [[ -n "$repo" ]] && ! timeout 10 getent hosts "$repo" >/dev/null; then
            d_msg "APT" "'$repo' cannot be resolved: name resolution does not work (check /etc/resolv.conf and the network).\n\n'apt update' is skipped, run it later." 10 70
            note "apt update skipped: $repo cannot be resolved"
        elif d_yesno "APT" "Run 'apt update' now?" 7 50; then
            d_info "APT" "apt update ..."
            run_cmd timeout 300 env DEBIAN_FRONTEND=noninteractive apt-get update
        fi
    fi
    # packages installed manually on the source host but missing here: shown, not installed
    [[ -s "$I/apt-manual.txt" ]] || return 0
    local cur p missing=()
    cur=$(apt-mark showmanual 2>/dev/null)
    while read -r p; do
        [[ -n "$p" ]] || continue
        grep -qxF "$p" <<<"$cur" && continue
        dpkg -s "$p" >/dev/null 2>&1 && continue
        missing+=("$p")
    done <"$I/apt-manual.txt"
    (( ${#missing[@]} )) || return 0
    printf '%s\n' "Installed manually on $SRC_HOST and missing here (${#missing[@]}):" "" "${missing[@]}" \
        "" "Install what you need, e.g.:" "  apt install <package> ..." >"$WORK/packages.txt"
    d_text "Missing packages" "$WORK/packages.txt"
    note "packages: ${#missing[@]} missing, list shown (${missing[*]})"
}

restore_system() {
    local snippets=() d
    while IFS= read -r d; do snippets+=("${d#"$F"}"); done < <(find "$F" -type d -name snippets -not -path "$F/etc/*" 2>/dev/null)
    local_component "Host settings" on "${LOCAL_SYSTEM[@]}" "${snippets[@]}"
}

# own files and folders from the include list of the backup
restore_extra() {
    local p
    ch_reset
    [[ -s "$I/extra.txt" ]] && while IFS= read -r p; do
        [[ -e "$F$p" || -L "$F$p" ]] && ch_add "$p" on "$F$p" "$p"
    done <"$I/extra.txt"
    ch_pick "Own files and folders" "From the include list of $SRC_HOST. Folders are merged: files are added/overwritten, nothing is deleted. Services using them are not restarted." || return 0
    ch_stage
    commit "Own files and folders"
}

restore_sshkeys() {
    local def=on k keys=()
    [[ "$MODE" == migrate ]] && def=off
    for k in "$F"/etc/ssh/ssh_host_* "$F"/root/.ssh/id_*; do [[ -e "$k" ]] && keys+=("${k#"$F"}"); done
    local_component "SSH host keys" "$def" "${keys[@]}"
}

# ===========================================================================
# Network (NIC mapping, review, apply with automatic rollback)
# ===========================================================================
restore_network() {
    [[ -f "$F/etc/network/interfaces" ]] || { note "network: no interfaces file in the backup"; return 0; }
    local cand="$WORK/net"; rm -rf "$cand"; mkdir -p "$cand/interfaces.d"
    local f p on i
    # every network file of the backup can be chosen; /etc/hosts and /etc/hostname only when
    # the node name stays (disaster recovery sets them in its hostname step)
    ch_reset
    ch_add /etc/network/interfaces on "$F/etc/network/interfaces" /etc/network/interfaces
    for f in "$F"/etc/network/interfaces.d/*; do
        [[ -f "$f" && "$(basename "$f")" != sdn ]] && ch_add "/etc/network/interfaces.d/$(basename "$f")" on "$f" "/etc/network/interfaces.d/$(basename "$f")"
    done
    for p in /etc/resolv.conf /etc/hosts /etc/hostname /etc/systemd/network /usr/local/lib/systemd/network; do
        [[ -e "$F$p" ]] || continue
        [[ "$MODE" != select && ( "$p" == /etc/hosts || "$p" == /etc/hostname ) ]] && continue
        on=on; [[ "$MODE" == migrate ]] && on=off
        ch_add "$p" "$on" "$F$p" "$p"
    done
    ch_pick "Network" "Select what to restore. resolv.conf and .link files (NIC names by MAC) belong to the old network and hardware:" || { note "network: skipped"; return 0; }
    local extra=()
    for i in $CH_SEL; do
        case "${CH_DST[$i]}" in
            /etc/network/interfaces) cp "${CH_SRC[$i]}" "$cand/interfaces" ;;
            /etc/network/interfaces.d/*) cp "${CH_SRC[$i]}" "$cand/interfaces.d/" ;;
            *) extra+=("$i") ;;
        esac
    done

    # --- NIC mapping by MAC ---
    local -A curmac=() newname=()
    local n name mac
    for n in /sys/class/net/*; do [[ -e "$n/device" ]] && curmac[${n##*/}]=$(cat "$n/address"); done
    if [[ -f "$I/nics.tsv" ]]; then
        while IFS=$'\t' read -r name mac _; do
            grep -qw -- "$name" "$cand/interfaces" "$cand"/interfaces.d/* 2>/dev/null || continue
            if [[ "${curmac[$name]:-}" == "$mac" ]]; then continue; fi
            local match=""
            for n in "${!curmac[@]}"; do [[ "${curmac[$n]}" == "$mac" ]] && match=$n; done
            if [[ -n "$match" ]]; then
                newname[$name]=$match
                note "network: $name -> $match (same MAC $mac)"
                continue
            fi
            local opts=(keep "keep the name $name")
            for n in $(printf '%s\n' "${!curmac[@]}" | sort); do opts+=("$n" "MAC ${curmac[$n]}"); done
            local pick
            pick=$(d_menu "NIC mapping" "The backup uses NIC '$name' (MAC $mac), which does not exist here.\nWhich NIC of this host should take its place?" "${opts[@]}") || pick=keep
            [[ "$pick" != keep ]] && { newname[$name]=$pick; note "network: $name -> $pick (chosen)"; }
        done <"$I/nics.tsv"
    fi
    if (( ${#newname[@]} )); then
        # two passes over placeholders, so that swapped names (eno1 <-> eno2) do not collide
        local k=0 old
        for old in "${!newname[@]}"; do
            sed -i "s/\b${old}\b/@@NIC${k}@@/g" "$cand/interfaces" "$cand"/interfaces.d/* 2>/dev/null
            k=$((k+1))
        done
        k=0
        for old in "${!newname[@]}"; do
            sed -i "s/@@NIC${k}@@/${newname[$old]}/g" "$cand/interfaces" "$cand"/interfaces.d/* 2>/dev/null
            k=$((k+1))
        done
    fi

    # hook commands (iptables, sysctl, routes, ...) run on reload; the rollback only restores
    # the files and cannot undo what they changed at runtime
    local hooks
    hooks=$(grep -hcE '^[[:space:]]*(pre-up|up|post-up|down|pre-down|post-down)[[:space:]]' "$cand/interfaces" "$cand"/interfaces.d/* 2>/dev/null | awk '{s+=$1} END{print s+0}')
    if [[ "${hooks:-0}" -gt 0 ]]; then
        local ask=d_yesno
        [[ "$MODE" != migrate ]] && ask=d_noyes
        if $ask "Network: hook commands" "The network configuration of $SRC_HOST runs $hooks hook command(s) (pre-up/up/post-up/down: iptables, sysctl, routes, ...).\n\nThey are executed when the network is reloaded and are NOT undone by the automatic rollback (e.g. NAT rules stay active).\n\nComment them out (prefix '#pcb# ')? You can re-enable single lines in the next editor." 15 76; then
            sed -i -E 's/^([[:space:]]*)(pre-up|up|post-up|down|pre-down|post-down)([[:space:]])/\1#pcb# \2\3/' "$cand/interfaces" "$cand"/interfaces.d/* 2>/dev/null
            note "network: $hooks hook command(s) commented out"
        fi
    fi

    if [[ -f "$cand/interfaces" ]]; then
        d_msg "Network" "Next you can review and edit /etc/network/interfaces as it will be written.\n\nCheck the IP addresses and gateway: this host keeps them only if they are right. After writing, the network is reloaded and automatically rolled back after 120 s unless you confirm." 13 76
        if d_edit "/etc/network/interfaces (from $SRC_HOST, edit if needed)" "$cand/interfaces"; then
            stage "$cand/interfaces" /etc/network/interfaces
        else
            note "network: /etc/network/interfaces skipped"
        fi
    fi
    for f in "$cand"/interfaces.d/*; do [[ -f "$f" ]] && stage "$f" "/etc/network/interfaces.d/$(basename "$f")"; done
    for i in "${extra[@]}"; do stage_path "${CH_SRC[$i]}" "${CH_DST[$i]}"; done

    local rb
    net_snapshot; rb=$REPLY
    commit "Network" || { rm -rf -- "$rb"; return 0; }
    post_hooks
    # reload only when an interfaces file was written
    printf '%s\n' "${COMMITTED[@]}" | grep -q '^/etc/network/interfaces' || { rm -rf -- "$rb"; return 0; }
    apply_network "$rb"
}

# net_snapshot -> REPLY = persistent copy of the current network config for the rollback
net_snapshot() {
    REPLY=""
    (( DRY_RUN )) && return 0
    REPLY="$NET_RB_DIR/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$REPLY" && cp -a /etc/network/interfaces "$REPLY/" \
        && { [[ -d /etc/network/interfaces.d ]] && cp -a /etc/network/interfaces.d "$REPLY/"; true; }
}

apply_network() {
    local rb=$1 script="/run/$RB_UNIT.sh" rc=0
    (( DRY_RUN )) && { note "[dry-run] would reload the network with rollback"; return 0; }
    if ! command -v ifreload >/dev/null; then
        note "network: ifupdown2 missing, the new configuration applies after a reboot"
        REBOOT_NEEDED=1
        return 0
    fi
    cat >"$script" <<EOF
#!/bin/bash
# written by $PROG: restore the network configuration saved before the restore
cp -a "$rb/interfaces" /etc/network/interfaces
if [ -d "$rb/interfaces.d" ]; then rm -rf /etc/network/interfaces.d; cp -a "$rb/interfaces.d" /etc/network/interfaces.d; fi
ifreload -a
EOF
    chmod 700 "$script"
    systemctl stop "$RB_UNIT.timer" "$RB_UNIT.service" >/dev/null 2>&1
    systemctl reset-failed "$RB_UNIT.timer" "$RB_UNIT.service" >/dev/null 2>&1
    systemd-run --quiet --unit="$RB_UNIT" --on-active=120 /bin/bash "$script" >>"$LOGFILE" 2>&1 \
        || { note "network: could not arm the rollback timer, not reloading; reboot to apply"; REBOOT_NEEDED=1; return 0; }
    d_info "Network" "Reloading the network (ifreload -a) ..."
    if ! ifreload -a >>"$LOGFILE" 2>&1; then
        systemctl stop "$RB_UNIT.timer" >/dev/null 2>&1
        bash "$script" >>"$LOGFILE" 2>&1
        rm -rf -- "$rb" "$script"
        note "network: ifreload failed, old configuration restored (see $LOGFILE)"
        d_msg "Network" "ifreload failed. The previous network configuration was restored.\n\nDetails in $LOGFILE." 10 70
        return 1
    fi
    dialog --backtitle "$BACKTITLE" --title "Network reloaded" --timeout 100 --yesno \
        "The new network configuration is active.\n\nIs this session (and the web UI) still reachable?\n\nYes keeps it. No, or no answer within 100 s, restores the previous configuration (the timer also fires if this connection is lost)." 13 72 2>/dev/tty || rc=$?
    systemctl stop "$RB_UNIT.timer" >/dev/null 2>&1
    if (( rc == 0 )); then
        note "network: new configuration confirmed"
    else
        bash "$script" >>"$LOGFILE" 2>&1
        note "network: not confirmed, previous configuration restored"
        d_msg "Network" "The previous network configuration was restored." 7 60
    fi
    # decided: the rollback copy is no longer needed (the undo point holds the old network too)
    rm -rf -- "$rb" "$script"
    (( rc == 0 ))
}

# ===========================================================================
# pmxcfs components (selective)
# ===========================================================================
storage_state() { # type id block-file -> ok | importable:<pool> | missing | remote
    local type=$1 blk=$2 v pool vg thin
    case "$type" in
        zfspool)
            pool=$(awk '$1=="pool"{print $2}' "$blk")
            zfs list -H -o name "$pool" >/dev/null 2>&1 && { echo ok; return; }
            # no "| grep -q" under pipefail: an early grep exit makes the writer fail with SIGPIPE
            grep -q "pool: ${pool%%/*}$" <<<"$(zpool import 2>/dev/null)" && { echo "importable:${pool%%/*}"; return; }
            echo missing ;;
        lvm)
            vg=$(awk '$1=="vgname"{print $2}' "$blk")
            vgs "$vg" >/dev/null 2>&1 && echo ok || echo missing ;;
        lvmthin)
            vg=$(awk '$1=="vgname"{print $2}' "$blk"); thin=$(awk '$1=="thinpool"{print $2}' "$blk")
            lvs "$vg/$thin" >/dev/null 2>&1 && echo ok || echo missing ;;
        dir|btrfs)
            v=$(awk '$1=="path"{print $2}' "$blk")
            [[ -d "$v" ]] && echo ok || echo missing ;;
        *) echo remote ;;
    esac
}

restore_storage() {
    local bak="$P/storage.cfg" cur="$PVE_DIR/storage.cfg"
    [[ -f "$bak" ]] || { note "storage: none in the backup"; return 0; }
    local items=() types=() ids=() line type id st blk idx=0 label
    while read -r type id; do
        type=${type%:}
        blk="$WORK/sc.$idx"; sc_get "$bak" "$id" >"$blk"
        st=$(storage_state "$type" "$blk")
        label="$type"
        if grep -qxF "$id" <<<"$(sc_ids "$cur" | awk '{print $2}')"; then label+=", exists here"; else label+=", new"; fi
        case "$st" in
            ok) label+=", backing store found" ;;
            importable:*) label+=", ZFS pool ${st#importable:} importable" ;;
            missing) label+=", backing store MISSING" ;;
            remote) label+=", network storage" ;;
        esac
        items+=("$id" "$label" on); types+=("$type"); ids+=("$id")
        idx=$((idx+1))
    done < <(sc_ids "$bak")
    local sel
    sel=$(d_check "Storages" "Storages from the backup. A storage whose pool/VG/path is missing is added disabled." "${items[@]}") || return 0
    [[ -n "$sel" ]] || return 0
    local selected=() disable=() i
    mapfile -t selected <<<"$sel"
    for id in "${selected[@]}"; do
        for i in "${!ids[@]}"; do [[ "${ids[$i]}" == "$id" ]] && break; done
        st=$(storage_state "${types[$i]}" "$WORK/sc.$i")
        if [[ "$st" == importable:* ]]; then
            local pool=${st#importable:}
            if d_yesno "ZFS pool" "Storage '$id' needs the ZFS pool '$pool', which is present but not imported.\n\nImport it now? (zpool import -f $pool)" 10 70; then
                run_cmd zpool import -f "$pool" || disable+=("$id")
            else
                disable+=("$id")
            fi
        elif [[ "$st" == missing ]]; then
            disable+=("$id")
        fi
    done
    # an unchanged storage keeps its state here; only added or changed ones are disabled
    local keep=()
    for id in "${disable[@]}"; do
        [[ "$(sc_get "$cur" "$id")" == "$(sc_get "$bak" "$id")" ]] || keep+=("$id")
    done
    disable=("${keep[@]}")
    local new="$WORK/storage.cfg"
    sc_merge "$cur" "$bak" "$new" "${selected[@]}"
    rename_nodes "$new"
    stage "$new" "$cur"
    local pf
    for id in "${selected[@]}"; do
        for pf in "$P"/priv/storage/"$id".*; do [[ -f "$pf" ]] && stage "$pf" "$PVE_DIR/priv/storage/$(basename "$pf")"; done
    done
    commit "Storages" || return 0
    (( ${#COMMITTED[@]} )) || return 0
    for id in "${disable[@]}"; do run_cmd pvesm set "$id" --disable 1; done
}

# acl_normalize: stdin user.cfg -> stdout; ACL lines (acl:propagate:path:ugids:roles:) are split
# into single rights, duplicates dropped, and grouped again like Proxmox VE does: one line per
# propagate/path/role set with all its users and groups. A file written by PVE stays as it is.
acl_normalize() {
    awk -F: '
        $1 != "acl" { print; next }
        {
            nu = split($4, u, ","); nr = split($5, r, ",")
            for (i = 1; i <= nu; i++) {
                k = $2 FS $3 FS u[i]
                if (!(k in roles)) { order[++n] = k; roles[k] = "" }
                for (j = 1; j <= nr; j++) if (index("," roles[k] ",", "," r[j] ",") == 0)
                    roles[k] = roles[k] (roles[k] == "" ? "" : ",") r[j]
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                split(order[i], a, FS); g = a[1] FS a[2] FS roles[order[i]]
                if (!(g in ugids)) { gorder[++m] = g; ugids[g] = a[3] } else ugids[g] = ugids[g] "," a[3]
            }
            for (i = 1; i <= m; i++) { split(gorder[i], a, FS); print "acl:" a[1] ":" a[2] ":" ugids[gorder[i]] ":" a[3] ":" }
        }'
}

# same_lines a b : true when both files hold the same non-empty lines, in any order
same_lines() {
    [[ -f "$1" && -f "$2" ]] && cmp -s <(grep -v '^$' "$1" | sort) <(grep -v '^$' "$2" | sort)
}

# merge_by_key sep current backup out key... : lines of current whose first field is not a key,
# plus the lines of backup whose first field is a key
merge_by_key() {
    local sep=$1 cur=$2 bak=$3 out=$4; shift 4
    [[ -f "$cur" ]] || cur=/dev/null
    printf '%s\n' "$@" >"$out.keys"
    awk -F"$sep" -v kf="$out.keys" -v curf="$cur" '
        BEGIN { while ((getline k < kf) > 0) sel[k] = 1 }
        FILENAME == curf { if (!($1 in sel)) print; next }
        ($1 in sel)' "$cur" "$bak" >"$out"
}

restore_users() {
    local bak="$P/user.cfg"
    [[ -f "$bak" ]] || { note "users: no user.cfg in the backup"; return 0; }
    local items=() keys=() idx=0 line type id rest label
    while IFS= read -r line; do
        [[ "$line" == *:* ]] || continue
        type=${line%%:*}; rest=${line#*:}
        case "$type" in
            user|group|role|pool|token) id=${rest%%:*}; [[ "$type:$id" == "user:root@pam" ]] && continue
                keys+=("$type:$id"); label="$type $id" ;;
            acl) keys+=("$line"); IFS=: read -r _ _ path ugid roles _ <<<"$line"; label="acl $path  $ugid  $roles" ;;
            *) continue ;;
        esac
        # same entry here: identical, or (users, tokens, ...) replaced by the backup version
        if grep -qxF "$line" "$PVE_DIR/user.cfg" 2>/dev/null; then label+="  [same here]"
        elif [[ "$type" != acl ]] && awk -F: -v t="$type" -v i="$id" '$1 == t && $2 == i { f = 1 } END { exit !f }' "$PVE_DIR/user.cfg" 2>/dev/null; then
            label+="  [exists here, replaced]"
        fi
        items+=("$idx" "$label" on); idx=$((idx+1))
    done <"$bak"
    local realms=() r
    while read -r _ r; do [[ "$r" == pam || "$r" == pve ]] && continue; realms+=("$r"); items+=("R$r" "realm $r" on); done < <(sc_ids "$P/domains.cfg")
    (( ${#items[@]} )) || return 0
    local sel s selkeys=() selusers=() seltokens=() selrealms=()
    sel=$(d_check "Users, tokens, ACLs" "Entries of user.cfg / domains.cfg. Selected entries replace the ones here; root@pam is never touched. Passwords (pve realm), 2FA and token secrets come along." "${items[@]}") || return 0
    for s in $sel; do
        if [[ "$s" == R* ]]; then selrealms+=("${s#R}"); continue; fi
        selkeys+=("${keys[$s]}")
        case "${keys[$s]}" in user:*) selusers+=("${keys[$s]#user:}") ;; token:*) seltokens+=("${keys[$s]#token:}") ;; esac
    done
    # user.cfg
    if (( ${#selkeys[@]} )); then
        local new="$WORK/user.cfg"
        printf '%s\n' "${selkeys[@]}" >"$WORK/userkeys"
        awk -F: -v keysf="$WORK/userkeys" -v curf="$PVE_DIR/user.cfg" '
            function key(l,  t, a){ split(l, a, ":"); t=a[1]; return (t=="acl") ? l : t":"a[2] }
            function rank(t){ return t=="user"?1 : t=="token"?2 : t=="group"?3 : t=="pool"?4 : t=="role"?5 : t=="acl"?6 : 7 }
            BEGIN{ while((getline k < keysf)>0) sel[k]=1;
                   n=0; while((getline l < curf)>0){ if(l=="") continue; if(!(key(l) in sel)){ split(l,a,":"); print rank(a[1]) "\t" (n++) "\t" l } } }
            $0!="" && (key($0) in sel){ print rank($1) "\t" (100000+NR) "\t" $0 }' "$bak" \
            | sort -t$'\t' -k1,1n -k2,2n | cut -f3- | acl_normalize >"$new"
        # the merge groups the lines by type; same lines in another order is no change
        same_lines "$new" "$PVE_DIR/user.cfg" || stage "$new" "$PVE_DIR/user.cfg"
    fi
    # pve realm passwords (key: user name with or without @pve) and token secrets
    local u pwkeys=()
    for u in "${selusers[@]}"; do [[ "$u" == *@pve ]] && pwkeys+=("${u%@pve}" "$u"); done
    if (( ${#pwkeys[@]} )) && [[ -f "$P/priv/shadow.cfg" ]]; then
        merge_by_key : "$PVE_DIR/priv/shadow.cfg" "$P/priv/shadow.cfg" "$WORK/shadow.cfg" "${pwkeys[@]}"
        same_lines "$WORK/shadow.cfg" "$PVE_DIR/priv/shadow.cfg" || stage "$WORK/shadow.cfg" "$PVE_DIR/priv/shadow.cfg"
    fi
    if (( ${#seltokens[@]} )) && [[ -f "$P/priv/token.cfg" ]]; then
        merge_by_key ' ' "$PVE_DIR/priv/token.cfg" "$P/priv/token.cfg" "$WORK/token.cfg" "${seltokens[@]}"
        same_lines "$WORK/token.cfg" "$PVE_DIR/priv/token.cfg" || stage "$WORK/token.cfg" "$PVE_DIR/priv/token.cfg"
    fi
    # 2FA (JSON since PVE 7)
    if (( ${#selusers[@]} )) && [[ -f "$P/priv/tfa.cfg" ]] && jq -e . "$P/priv/tfa.cfg" >/dev/null 2>&1; then
        local tf="$WORK/tfa.cfg"
        if [[ -f "$PVE_DIR/priv/tfa.cfg" ]] && jq -e . "$PVE_DIR/priv/tfa.cfg" >/dev/null 2>&1; then cp "$PVE_DIR/priv/tfa.cfg" "$tf"; else echo '{}' >"$tf"; fi
        for u in "${selusers[@]}"; do
            jq -c --arg u "$u" --slurpfile b "$P/priv/tfa.cfg" \
                'if ($b[0].users[$u] // null) != null then .users[$u] = $b[0].users[$u] else . end' "$tf" >"$tf.2" && mv "$tf.2" "$tf"
        done
        # written only when the content differs (formatting alone is no change)
        jq -e . "$tf" >/dev/null 2>&1 \
            && ! jq -e -n --slurpfile a "$tf" --slurpfile b "$PVE_DIR/priv/tfa.cfg" '$a == $b' >/dev/null 2>&1 \
            && stage "$tf" "$PVE_DIR/priv/tfa.cfg"
    fi
    # realms
    if (( ${#selrealms[@]} )); then
        local dn="$WORK/domains.cfg"
        sc_merge "$PVE_DIR/domains.cfg" "$P/domains.cfg" "$dn" "${selrealms[@]}"
        stage "$dn" "$PVE_DIR/domains.cfg"
        for r in "${selrealms[@]}"; do
            [[ -f "$P/priv/realm/$r.pw" ]] && stage "$P/priv/realm/$r.pw" "$PVE_DIR/priv/realm/$r.pw"
        done
    fi
    commit "Users, tokens, ACLs"
}

# datacenter.cfg and the legacy vzdump.cron are whole files; the other datacenter files are
# section configs and are merged per entry, so entries that exist only on this host stay
restore_datacenter() {
    local f
    ch_reset
    for f in datacenter.cfg vzdump.cron; do
        [[ -f "$P/$f" ]] && ! cmp -s "$P/$f" "$PVE_DIR/$f" \
            && ch_add "$f ($([[ -f $PVE_DIR/$f ]] && echo changed || echo new))" on "$P/$f" "$PVE_DIR/$f"
    done
    ch_pick "Datacenter settings" "Whole files are replaced:" && { ch_stage; commit "Datacenter settings"; }
    restore_sections "Jobs, replication, notifications" "Entries are merged: selected entries are added or replaced, entries that exist only on this host stay." "" \
        jobs.cfg replication.cfg notifications.cfg priv/notifications.cfg status.cfg virtual-guest/cpu-models.conf
}

restore_firewall() {
    ch_reset
    [[ -f "$P/firewall/cluster.fw" ]] && ch_add "cluster.fw (datacenter rules, IP sets, aliases, groups)" on "$P/firewall/cluster.fw" "$PVE_DIR/firewall/cluster.fw"
    [[ -f "$P/nodes/$OLD_NODE/host.fw" ]] && ch_add "host.fw of $OLD_NODE -> $CUR_HOST" on "$P/nodes/$OLD_NODE/host.fw" "$PVE_DIR/nodes/$CUR_HOST/host.fw"
    ch_pick "Firewall" "Guest firewall files come with the guests.\nWARNING: cluster.fw may enable the firewall. Make sure its rules allow access to THIS host's IP, or you lock yourself out." || return 0
    ch_stage
    commit "Firewall" || return 0
    (( ${#COMMITTED[@]} && ! DRY_RUN )) || return 0
    if pve-firewall compile >/dev/null 2>>"$LOGFILE"; then note "firewall: rules compile OK"; else note "firewall: pve-firewall compile reported errors, check $LOGFILE"; fi
}

restore_sdn() {
    local f files=() changed=0
    for f in "$P"/sdn/*.cfg; do [[ -f "$f" ]] && files+=("${f##*/}"); done
    COMMITTED=()   # restore_sections may return without a commit
    # zones, vnets, subnets, ... are section configs: merged per entry, entries of this host stay
    (( ${#files[@]} )) && restore_sections "SDN" "Zones, vnets, subnets, controllers, IPAMs, DNS, fabrics. Entries are merged, entries that exist only on this host stay." sdn "${files[@]}"
    (( ${#COMMITTED[@]} )) && changed=1
    # state of the built-in IPAM (allocated IPs, gateways, DHCP leases) and the MAC cache;
    # applying the configuration does not rebuild them. Merged: entries of this host stay,
    # the backup wins where both have the same entry
    ch_reset
    for f in "$P"/sdn/pve-ipam-state.json "$P"/sdn/mac-cache.json; do
        [[ -f "$f" ]] || continue
        if [[ -s "$PVE_DIR/sdn/${f##*/}" ]]; then
            jq -c -s '.[0] * .[1]' "$PVE_DIR/sdn/${f##*/}" "$f" >"$WORK/${f##*/}" 2>>"$LOGFILE" || cp "$f" "$WORK/${f##*/}"
        else
            cp "$f" "$WORK/${f##*/}"
        fi
        ch_add "${f#"$P"/}  (IPAM state, merged)" on "$WORK/${f##*/}" "$PVE_DIR/${f#"$P"/}"
    done
    if (( ${#CH_LABEL[@]} )) && ch_pick "SDN: IPAM state" "Allocated IPs, gateways and DHCP leases of the built-in IPAM. Applying the configuration does not rebuild them."; then
        ch_stage
        commit "SDN: IPAM state" && (( ${#COMMITTED[@]} )) && changed=1
    fi
    (( changed )) || return 0
    d_yesno "SDN" "Apply the SDN configuration now? (pvesh set /cluster/sdn)" 7 64 && run_cmd pvesh set /cluster/sdn
}

# restore_sections title text dir file... : pick single sections of section-config files below
# $P/dir (dir may be empty), merge them into the files here
restore_sections() {
    local title=$1 text=$2 dir=${3:+$3/}; shift 3
    local f type id on label
    ch_reset
    for f in "$@"; do
        [[ -f "$P/$dir$f" ]] || continue
        while read -r type id; do
            on=on; label="${f%.c*}: ${type%:} $id"
            [[ "${type%:}" == "$id" ]] && label="${f%.c*}: $id"
            if [[ "$dir$f" == ha/resources.cfg ]] && ! vmid_exists "$id"; then label+=" [guest missing]"; on=off; fi
            ch_add "$label" "$on" "$dir$f" "$id"      # source = file below /etc/pve, target = section id
        done < <(sc_ids "$P/$dir$f")
    done
    ch_pick "$title" "$text" || return 0
    local -A byfile=()
    local i out id
    for i in $CH_SEL; do byfile[${CH_SRC[$i]}]+="${CH_DST[$i]} "; done
    for f in "${!byfile[@]}"; do
        out="$WORK/sc.${f//\//_}"
        # shellcheck disable=SC2086
        sc_merge "$PVE_DIR/$f" "$P/$f" "$out" ${byfile[$f]}
        rename_nodes "$out"
        stage "$out" "$PVE_DIR/$f"
        # secrets of these sections live in their own files below priv/
        if [[ "$f" == status.cfg ]]; then
            for id in ${byfile[$f]}; do
                [[ -f "$P/priv/metricserver/$id.pw" ]] && stage "$P/priv/metricserver/$id.pw" "$PVE_DIR/priv/metricserver/$id.pw"
            done
        fi
    done
    commit "$title" || return 0
    [[ " ${COMMITTED[*]} " == *" $PVE_DIR/jobs.cfg "* ]] && JOBS_RESTORED=1
    return 0
}

restore_mapping() {
    local f files=()
    for f in "$P"/mapping/*.cfg; do [[ -f "$f" ]] && files+=("${f##*/}"); done
    restore_sections "Resource mappings" "PCI/USB/directory mappings point at hardware paths of $OLD_NODE. On other hardware check them afterwards (Datacenter > Resource Mappings)." mapping "${files[@]}"
}

restore_ha() {
    restore_sections "High availability" "HA groups, resources and rules. Resources whose guest does not exist here are preselected off." ha groups.cfg resources.cfg rules.cfg
}

vmid_exists() { jq -e --arg id "$1" '.ids[$id] != null' "$PVE_DIR/.vmlist" >/dev/null 2>&1; }
vmid_node()   { jq -r --arg id "$1" '.ids[$id].node // empty' "$PVE_DIR/.vmlist" 2>/dev/null; }

guest_storages() { # conf -> storage ids used by disks/ISOs (main section only)
    awk '/^\[/{exit} /^(ide|sata|scsi|virtio|efidisk|tpmstate|unused|rootfs|mp)[0-9]*:/{
            v=$0; sub(/^[^:]*:[ \t]*/, "", v); split(v, a, ","); v=a[1];
            if (v ~ /^\// || v=="none" || v !~ /:/) next; split(v, b, ":"); print b[1] }' "$1" | sort -u
}

restore_guests() {
    local items=() vmids=() paths=() types=() vmid type node name rel label idx=0
    while IFS=$'\t' read -r vmid type node name rel; do
        label="$type $name (node $node)"
        local on=on
        if vmid_exists "$vmid"; then label+=" [EXISTS on $(vmid_node "$vmid")]"; on=off; fi
        items+=("$idx" "$vmid  $label" "$on"); vmids+=("$vmid"); paths+=("$rel"); types+=("$type")
        idx=$((idx+1))
    done < <(guest_confs)
    (( ${#items[@]} )) || { note "guests: no guest configs in the backup"; return 0; }
    local sel s
    sel=$(d_check "Guests" "Guest configurations. Only the configs are restored; disks must exist (e.g. imported ZFS pool) or the guest is restored from PBS instead (that recreates config and disks)." "${items[@]}") || return 0
    local warn_txt="" st stores
    stores=$(sc_ids "$PVE_DIR/storage.cfg" | awk '{print $2}')
    for s in $sel; do
        vmid=${vmids[$s]}; rel=${paths[$s]}
        if vmid_exists "$vmid"; then
            if [[ "$(vmid_node "$vmid")" != "$CUR_HOST" ]]; then
                note "guest $vmid: exists on another node, skipped"; continue
            fi
            d_noyes "Guest $vmid" "VMID $vmid already exists on this host.\n\nOverwrite its configuration with the one from the backup?" 9 64 || { note "guest $vmid: kept existing"; continue; }
        fi
        for st in $(guest_storages "$P/$rel"); do
            grep -qxF "$st" <<<"$stores" || warn_txt+="  $vmid uses storage '$st', which does not exist here\n"
        done
        local dir=qemu-server; [[ "${types[$s]}" == CT ]] && dir=lxc
        stage "$P/$rel" "$PVE_DIR/nodes/$CUR_HOST/$dir/$vmid.conf"
        [[ -f "$P/firewall/$vmid.fw" ]] && stage "$P/firewall/$vmid.fw" "$PVE_DIR/firewall/$vmid.fw"
        RESTORED_VMIDS+=("$vmid")
    done
    [[ -n "$warn_txt" ]] && d_msg "Guests: missing storages" "$warn_txt\nThese guests will not start until the storage exists. Restore the storages first or restore the guests from PBS." 16 76
    commit "Guests" || RESTORED_VMIDS=()
}

restore_certs() {
    local f n=$OLD_NODE cert_on=off i
    [[ "$OLD_NODE" == "$CUR_HOST" ]] && cert_on=on
    # DNS plugins are a section config: merged per entry
    [[ -f "$P/priv/acme/plugins.cfg" ]] && restore_sections "ACME plugins" "DNS challenge plugins. Entries are merged, plugins of this host stay." priv/acme plugins.cfg
    ch_reset
    for f in "$P"/priv/acme/*; do [[ -f "$f" && "${f##*/}" != plugins.cfg ]] && ch_add "ACME account ${f##*/}" on "$f" "$PVE_DIR/priv/acme/${f##*/}"; done
    [[ -f "$P/nodes/$n/config" ]] && ch_add "node config of $n (ACME domains, description, wake-on-LAN)" on "$P/nodes/$n/config" "$PVE_DIR/nodes/$CUR_HOST/config"
    [[ -f "$P/nodes/$n/pveproxy-ssl.pem" && -f "$P/nodes/$n/pveproxy-ssl.key" ]] \
        && ch_add "own web certificate: uploaded or ACME (pveproxy-ssl.pem/.key)" "$cert_on" "$P/nodes/$n/pveproxy-ssl.pem" "$PVE_DIR/nodes/$CUR_HOST/pveproxy-ssl.pem"
    ch_pick "Certificates" "The web certificate is issued for $n's name; only take it over if this host answers under that name." || return 0
    ch_stage
    for i in $CH_SEL; do   # the key belongs to the certificate
        [[ "${CH_DST[$i]}" == *pveproxy-ssl.pem ]] && stage "${CH_SRC[$i]%.pem}.key" "${CH_DST[$i]%.pem}.key"
    done
    commit "Certificates" || return 0
    printf '%s\n' "${COMMITTED[@]}" | grep -q 'pveproxy-ssl' && run_cmd systemctl restart pveproxy
    return 0
}

# Node identity (only onto the same node name): cluster CA, node certificate signed by it,
# ticket auth keys and CSRF key. They belong together and are restored as one set.
restore_identity() {
    [[ "$OLD_NODE" == "$CUR_HOST" ]] || { note "identity: only restored onto the same node name"; return 0; }
    local f files=(pve-root-ca.pem priv/pve-root-ca.key "nodes/$OLD_NODE/pve-ssl.pem" "nodes/$OLD_NODE/pve-ssl.key"
                   authkey.pub priv/authkey.key pve-www.key)
    for f in "${files[@]}"; do
        [[ -f "$P/$f" ]] || { note "identity: $f missing in the backup, skipped"; return 0; }
    done
    d_yesno "Node identity" "Restore the self-signed certificates of Proxmox VE (pve-ssl.pem and the PVE CA that signed it) and the auth keys of $OLD_NODE as one set?\n\nBrowsers and API clients that trusted the old certificate trust it again. Current web UI sessions end (new login needed)." 12 72 || return 0
    for f in "${files[@]}"; do stage "$P/$f" "$PVE_DIR/$f"; done
    commit "Node identity" || return 0
    (( ${#COMMITTED[@]} )) && run_cmd systemctl restart pvedaemon pveproxy
    return 0
}

restore_rrd() {
    local base="$F$RRD_DIR" sub copied=0
    [[ -d "$base" ]] || { note "rrd: no statistics in the backup"; return 0; }
    d_yesno "Statistics" "Copy the RRD statistics (graphs) of $OLD_NODE${RESTORED_VMIDS[*]:+ and the restored guests} to this host?" 8 72 || return 0
    (( DRY_RUN )) && { note "[dry-run] would copy RRD data"; return 0; }
    systemctl stop rrdcached >>"$LOGFILE" 2>&1
    for sub in "$base"/*; do
        [[ -d "$sub" ]] || continue
        local s=${sub##*/}
        case "$s" in
            *node*|*storage*)
                if [[ -e "$sub/$OLD_NODE" ]]; then
                    (umask 022; mkdir -p "$RRD_DIR/$s")
                    rm -rf "${RRD_DIR:?}/$s/$CUR_HOST"
                    cp -a "$sub/$OLD_NODE" "$RRD_DIR/$s/$CUR_HOST" && copied=1
                fi ;;
            *vm*)
                local v
                for v in "${RESTORED_VMIDS[@]}"; do
                    [[ -e "$sub/$v" ]] && { (umask 022; mkdir -p "$RRD_DIR/$s"); cp -a "$sub/$v" "$RRD_DIR/$s/"; copied=1; }
                done ;;
        esac
    done
    systemctl start rrdcached >>"$LOGFILE" 2>&1
    if (( copied )); then CHANGES=$((CHANGES+1)); note "rrd: statistics copied"; else note "rrd: nothing matched"; fi
}

restore_cluster_guided() {
    local cname members
    cname=$(m .cluster_name)
    members=$(m '[.cluster_nodes[] | "  " + .name + "  " + .ip] | join("\n")')
    if [[ -f "$PVE_DIR/corosync.conf" ]]; then
        d_msg "Cluster" "This host is already a cluster member. Nothing to do." 7 60
        return 0
    fi
    local choice opts=(skip "leave this host standalone")
    [[ -n "$cname" ]] && opts+=(create "create a new cluster named '$cname' here")
    opts+=(join "join an existing cluster")
    choice=$(d_menu "Cluster" "Backup: cluster '${cname:-none}'\n${members}\n\nCorosync keys are never copied. Choose how to (re)build:" "${opts[@]}") || return 0
    case "$choice" in
        create)
            d_yesno "Cluster" "Run 'pvecm create $cname' now?" 7 60 && run_cmd pvecm create "$cname" ;;
        join) cluster_join ;;
    esac
}

cluster_join() {
    if jq -e '(.ids // {}) | length > 0' "$PVE_DIR/.vmlist" >/dev/null 2>&1; then
        d_msg "Cluster join" "This host has guests. A node that joins a cluster must not have any guests (VMID conflicts). Move or remove them first." 9 72
        return 1
    fi
    local opts=() n ip
    while IFS=$'\t' read -r n ip; do
        [[ -z "$n" || "$n" == "$CUR_HOST" ]] && continue
        opts+=("$ip" "$n")
    done < <(m '.cluster_nodes[] | [.name, .ip] | @tsv')
    opts+=(other "enter an IP address")
    ip=$(d_menu "Cluster join" "Join via which existing cluster node?" "${opts[@]}") || return 0
    [[ "$ip" == other ]] && { ip=$(d_input "Cluster join" "IP or hostname of a cluster node:") || return 0; }
    d_msg "Cluster join" "Before joining, on a remaining cluster node:\n\n  pvecm delnode $SRC_HOST\n\n(only if this node was a member under that name and is not yet removed).\n\nThe join asks for the root password of $ip. Everything in /etc/pve is then taken from the cluster." 14 76
    d_yesno "Cluster join" "Run 'pvecm add $ip' now?" 7 60 || return 0
    if (( DRY_RUN )); then note "[dry-run] would run: pvecm add $ip"; return 0; fi
    clear
    echo "Running: pvecm add $ip"
    if pvecm add "$ip"; then
        note "cluster: joined via $ip"
        pvecm updatecerts >>"$LOGFILE" 2>&1 && note "cluster: pvecm updatecerts done"
    else
        note "FAILED: pvecm add $ip"
    fi
    read -rp "Press Enter to continue ..." _
}

# ===========================================================================
# Full disaster recovery (replace config.db)
# ===========================================================================
dr_hostname() {
    if [[ "$CUR_HOST" == "$SRC_HOST" ]]; then return 0; fi
    local cand="$WORK/hosts"
    [[ -f "$F/etc/hosts" ]] && cp "$F/etc/hosts" "$cand" || cp /etc/hosts "$cand"
    d_msg "Hostname" "Disaster recovery restores the node '$SRC_HOST', this host is called '$CUR_HOST'.\n\nThe node name must match. Next: review /etc/hosts; the line for $SRC_HOST must carry an IP this host has (now or after the network restore)." 12 76
    d_edit "/etc/hosts for $SRC_HOST" "$cand" || return 1
    # pmxcfs needs the node name to resolve to an address of this host
    local ips a ok=0
    ips=$(awk -v h="$SRC_HOST" '$1 !~ /^#/ && $1 !~ /^127\./ && $1 != "::1" { for (i = 2; i <= NF; i++) if ($i == h) print $1 }' "$cand")
    local addrs; addrs=$(ip -o addr)
    for a in $ips; do grep -qwF "$a" <<<"$addrs" && ok=1; done
    if (( ! ok )); then
        d_noyes "Hostname" "None of the addresses for $SRC_HOST in /etc/hosts (${ips:-none}) is configured on this host right now.\n\nAddresses here: $(awk '$2 != "lo" {print $4}' <<<"$addrs" | tr '\n' ' ')\n\npve-cluster only starts when the node name resolves to an address of this host, i.e. after the restored network is active (reboot).\n\nContinue anyway?" 16 76 || return 1
    fi
    printf '%s\n' "$SRC_HOST" >"$WORK/hostname"
    stage "$cand" /etc/hosts
    stage "$WORK/hostname" /etc/hostname
    commit "Hostname" || return 1
}

PVE_SERVICES="pvedaemon pveproxy pvestatd pvescheduler pve-ha-crm pve-ha-lrm"   # all use pmxcfs

pve_start() { # start pve-cluster, then the services that depend on it
    systemctl start pve-cluster >>"$LOGFILE" 2>&1 || return 1
    # shellcheck disable=SC2086
    systemctl start $PVE_SERVICES >>"$LOGFILE" 2>&1
}

# prints the problems of the Proxmox VE services, one per line; nothing when all is well
pve_health() {
    local svc
    mountpoint -q "$PVE_DIR" || echo "$PVE_DIR is not mounted"
    for svc in pve-cluster pvedaemon pveproxy pvestatd; do
        systemctl is-active -q "$svc" || echo "$svc is not running"
    done
    mountpoint -q "$PVE_DIR" && ! timeout 20 pvesh get /version >/dev/null 2>&1 && echo "the API does not answer"
    return 0
}

# offer to start the services when something is wrong; 0 = healthy afterwards
ensure_pve_running() {
    local problems
    problems=$(pve_health)
    [[ -z "$problems" ]] && return 0
    d_yesno "Proxmox VE services" "Problems found:\n\n  ${problems//$'\n'/\\n  }\n\nStart the services now?" 14 72 || return 1
    d_info "Proxmox VE services" "Starting pve-cluster and the services ..."
    pve_start; sleep 3
    problems=$(pve_health)
    if [[ -z "$problems" ]]; then note "services: started, all running"; return 0; fi
    { echo "Still not working:"; echo "$problems"; echo; echo "journalctl -u pve-cluster (last lines):"
      journalctl -u pve-cluster -n 25 --no-pager 2>&1; } >"${WORK:-/tmp}/health.txt"
    d_text "Proxmox VE services" "${WORK:-/tmp}/health.txt"
    note "services: still not working: $(tr '\n' ';' <<<"$problems")"
    return 1
}

dr_swap_db() {
    local dump="$X/pmxcfs/config.dump.sql" test="$WORK/config.db" ts
    [[ -s "$dump" ]] || die "The backup contains no config.db dump."
    need_cmds sqlite3:sqlite3
    sqlite3 "$test" <"$dump" 2>>"$LOGFILE" || die "Building config.db from the dump failed."
    [[ "$(sqlite3 "$test" 'PRAGMA integrity_check;')" == ok ]] || die "The rebuilt config.db fails the integrity check."
    local n
    n=$(sqlite3 "$test" 'SELECT count(*) FROM tree;')
    d_noyes "Replace cluster database" "Now /var/lib/pve-cluster/config.db is replaced by the one from $SRC_HOST ($n entries): all of /etc/pve (guests, storages, users, tokens, firewall, SDN, HA, certificates) becomes the state of the backup.\n\npve-cluster is stopped for this. The old database stays as config.db.pre-restore-<time>.\n\nContinue?" 15 76 || { note "config.db: skipped by user"; return 1; }
    if (( DRY_RUN )); then note "[dry-run] would replace $DB"; return 0; fi
    ts=$(date +%Y%m%d-%H%M%S)
    # all services that talk to pmxcfs, then pmxcfs itself
    # shellcheck disable=SC2086
    systemctl stop $PVE_SERVICES >>"$LOGFILE" 2>&1
    systemctl stop pve-cluster >>"$LOGFILE" 2>&1
    pkill -x pmxcfs 2>/dev/null; sleep 2
    mv "$DB" "$DB.pre-restore-$ts" || { pve_start; die "Could not move the old config.db aside."; }
    local s
    for s in -wal -shm; do [[ -e "$DB$s" ]] && mv "$DB$s" "$DB.pre-restore-$ts$s"; done
    if ! install -m 600 -o root -g root "$test" "$DB"; then
        mv "$DB.pre-restore-$ts" "$DB"; pve_start
        die "Installing the new config.db failed, the old one is back."
    fi
    CHANGES=$((CHANGES+1))
    note "config.db replaced (old: $DB.pre-restore-$ts)"
    JOBS_RESTORED=1
    DB_BACKUP="$DB.pre-restore-$ts"
    [[ "$(hostname -s)" != "$(cat /etc/hostname)" ]] && run_cmd hostnamectl set-hostname "$(cat /etc/hostname)"
    if pve_start; then
        note "pve-cluster started with the restored database"
    else
        note "pve-cluster did not start yet (hostname/IP apply after reboot)"
    fi
    REBOOT_NEEDED=1
}

dr_prepare_storage() { # import ZFS pools / check VGs referenced by the backup storage.cfg
    [[ -f "$P/storage.cfg" ]] || return 0
    local type id blk st txt="" pool
    while read -r type id; do
        type=${type%:}; blk="$WORK/drsc.$id"; sc_get "$P/storage.cfg" "$id" >"$blk"
        st=$(storage_state "$type" "$blk")
        case "$st" in
            importable:*)
                pool=${st#importable:}
                if d_yesno "ZFS pool" "Storage '$id' uses the ZFS pool '$pool', which is present but not imported.\n\nImport it now? (zpool import -f $pool)" 10 70; then
                    run_cmd zpool import -f "$pool" || txt+="  $id: import of $pool failed\n"
                else
                    txt+="  $id: pool $pool not imported\n"
                fi ;;
            missing) txt+="  $id ($type): backing store not found\n" ;;
        esac
    done < <(sc_ids "$P/storage.cfg")
    [[ -n "$txt" ]] && d_msg "Storages" "These storages will not work after the restore:\n\n$txt\nCreate the pools/VGs/paths or disable the storages later." 16 76
    return 0
}

restore_dr() {
    local how=exact
    (( PMXCFS_UP )) && { how=$(d_menu "Full disaster recovery" "How should $SRC_HOST be restored?" \
        exact "everything, exactly (replace the cluster database) - fresh host only" \
        select "choose the parts (storages, users, guests, network, ... one by one)") || return 1; }
    if [[ "$how" == select ]]; then
        not_restorable "$([[ "$CUR_HOST" == "$SRC_HOST" ]] && echo select || echo migrate)" >"$WORK/notes.txt"
        d_text "Not restorable" "$WORK/notes.txt"
        if [[ "$CUR_HOST" != "$SRC_HOST" ]]; then
            d_msg "Selective restore" "This host is called '$CUR_HOST', the backup is from '$SRC_HOST'.\n\nThe chosen parts are taken over under the name '$CUR_HOST' (node names are rewritten, node certificates and keys stay). To get the old node identity back, install the host as '$SRC_HOST' or use the exact restore." 13 76
            MODE=migrate
        else
            MODE=select
        fi
        restore_migrate
        return
    fi
    not_restorable dr >"$WORK/notes.txt"
    d_text "Not restorable" "$WORK/notes.txt"
    if [[ -f "$PVE_DIR/corosync.conf" || -f /etc/corosync/corosync.conf ]]; then
        d_msg "Full disaster recovery" "This host is a cluster member. Replacing the database of a cluster member breaks the cluster. Use 'Selective migration' instead." 10 72
        return 1
    fi
    if (( ! PMXCFS_UP )); then
        d_noyes "Full disaster recovery" "With pve-cluster down the guests of this host cannot be checked.\n\nThe database from the backup replaces ALL configuration of this host (guests, storages, users, ...).\n\nContinue?" 12 72 || return 1
    elif jq -e '(.ids // {}) | length > 0' "$PVE_DIR/.vmlist" >/dev/null 2>&1; then
        d_msg "Full disaster recovery" "This host already has guests. Full recovery needs a freshly installed host (the documented pmxcfs recovery: 'with nothing running'). Use 'Selective migration' instead." 10 72
        return 1
    fi
    if [[ -n "$(m .cluster_name)" ]]; then
        d_noyes "Cluster backup" "$SRC_HOST was a member of cluster '$(m .cluster_name)'.\n\nFull recovery of a cluster member is only right if the WHOLE cluster is gone. If other nodes are alive, reinstall this node, run 'pvecm delnode $SRC_HOST' on a remaining node and join it again (Selective migration > cluster).\n\nAfter this recovery the node waits for quorum; 'pvecm expected 1' gives write access back.\n\nContinue with full recovery?" 17 76 || return 1
    fi
    local comps sel c
    comps=(network "network (interfaces, NIC mapping, rollback timer)" on
           apt "APT sources and keyrings (missing packages are listed)" on
           system "PVE host settings (vzdump, vfio, kernel, ZFS, sysctl, mail, snippets)" on)
    [[ -s "$I/extra.txt" ]] && comps+=(extra "own files and folders (include list)" on)
    comps+=(sshkeys "SSH host keys (keeps known_hosts of clients valid)" on
           db "cluster database (all of /etc/pve) - the core of the recovery" on
           rrd "RRD statistics (graphs)" on)
    sel=$(d_check "Full disaster recovery" "Restore order is fixed: network > apt > system > hostname > storages > database > statistics." "${comps[@]}") || return 1
    for c in network apt system extra sshkeys; do
        grep -qx "$c" <<<"$sel" || continue
        case "$c" in
            network) restore_network ;;
            apt) restore_apt ;;
            system) restore_system ;;
            extra) restore_extra ;;
            sshkeys) restore_sshkeys ;;
        esac
    done
    if grep -qx db <<<"$sel"; then
        dr_hostname || { note "hostname: not set, database not replaced"; return 0; }
        dr_prepare_storage
        dr_swap_db
    fi
    if grep -qx rrd <<<"$sel"; then
        OLD_NODE=$SRC_HOST; CUR_HOST=$(cat /etc/hostname 2>/dev/null || hostname -s)
        mapfile -t RESTORED_VMIDS < <(m '.guests[].vmid')
        restore_rrd
    fi
}

restore_migrate() {
    # which node of the backup provides node-specific files
    local nodes=() n
    for n in "$P"/nodes/*; do [[ -d "$n" ]] && nodes+=("${n##*/}"); done
    OLD_NODE=$SRC_HOST
    if (( ${#nodes[@]} > 1 )); then
        local opts=()
        for n in "${nodes[@]}"; do opts+=("$n" ""); done
        OLD_NODE=$(d_menu "Source node" "The backup holds several nodes. Whose node-specific settings (host firewall, node config, certificate, statistics) should this host take over?" "${opts[@]}") || return 1
    fi
    # selective restore onto the same node (MODE=select): everything preselected, node identity offered
    local same=off title text
    [[ "$MODE" == select ]] && same=on
    if [[ "$MODE" == select ]]; then
        title="Selective restore: $OLD_NODE"
        text="Choose the parts; each part then lets you pick single entries and shows a diff before writing."
    else
        title="Selective migration: $OLD_NODE -> $CUR_HOST"
        text="Node name references are rewritten from $OLD_NODE to $CUR_HOST. Node keys, cluster CA and SSL certs of the old node are never copied."
    fi
    local comps sel c
    comps=(storage "storages (storage.cfg + credentials), ZFS pool import" on
           users "users, groups, roles, ACLs, tokens, realms, 2FA" on
           datacenter "datacenter settings, backup/replication jobs, notifications" on
           mapping "resource mappings (PCI/USB/dir)" "$same"
           sdn "SDN" on
           firewall "firewall (cluster.fw, host.fw)" on
           guests "guest configurations (VM/CT)" on
           ha "HA groups/resources/rules" on
           certs "certificates: own web certificate, ACME accounts/plugins, node config" on
           network "network (interfaces with NIC mapping)" "$same"
           apt "APT sources and keyrings (missing packages are listed)" on
           system "PVE host settings (vzdump, vfio, kernel, ZFS, sysctl, mail, snippets)" on)
    [[ -s "$I/extra.txt" ]] && comps+=(extra "own files and folders (include list)" "$same")
    comps+=(sshkeys "SSH host keys of $OLD_NODE" "$same")
    [[ "$MODE" == select ]] && comps+=(identity "node identity: self-signed PVE certificate and CA, auth keys" on)
    comps+=(rrd "RRD statistics" "$same"
            cluster "cluster: create or join (guided)" off)
    sel=$(d_check "$title" "$text" "${comps[@]}") || return 1
    for c in apt system extra sshkeys network storage users datacenter mapping sdn firewall cluster identity guests ha certs rrd; do
        grep -qx "$c" <<<"$sel" || continue
        case "$c" in
            apt) restore_apt ;;
            system) restore_system ;;
            extra) restore_extra ;;
            sshkeys) restore_sshkeys ;;
            network) restore_network ;;
            storage) restore_storage ;;
            users) restore_users ;;
            datacenter) restore_datacenter ;;
            mapping) restore_mapping ;;
            sdn) restore_sdn ;;
            firewall) restore_firewall ;;
            cluster) restore_cluster_guided ;;
            identity) restore_identity ;;
            guests) restore_guests ;;
            ha) restore_ha ;;
            certs) restore_certs ;;
            rrd) restore_rrd ;;
        esac
    done
}

# Roll this host back to one of its own backups (normally the undo point of a restore):
# the database is replaced exactly, files the restore created are removed again.
restore_undo() {
    if [[ -f "$PVE_DIR/corosync.conf" ]]; then
        d_msg "Undo" "This host is a cluster member; its database cannot be replaced. Undo the changes with 'Selective migration' instead." 9 72
        return 1
    fi
    local running
    running=$( { qm list 2>/dev/null; pct list 2>/dev/null; } | awk '$0 ~ / running /' | wc -l)
    (( running )) && { d_noyes "Undo" "$running guest(s) are running. Their configuration files are reset while they run.\n\nContinue?" 10 70 || return 1; }
    local created="$ARCHIVE_FILE.created" sel c
    local comps=(db "database (/etc/pve) exactly as in the backup" on)
    [[ -s "$created" ]] && comps+=(created "remove the $(wc -l <"$created") file(s) the restore created" on)
    # network on when the network files of the backup differ from the current ones
    local net=off f2
    for f2 in /etc/network/interfaces /etc/network/interfaces.d; do
        diff -rq "$F$f2" "$f2" >/dev/null 2>&1 || net=on
    done
    comps+=(apt "APT sources/keyrings: changed files back" on system "host settings for PVE: changed files back" on
            network "network files (reload with rollback timer)" "$net")
    [[ -s "$I/extra.txt" ]] && comps+=(extra "own files and folders: changed files back" on)
    sel=$(d_check "Undo" "Roll $CUR_HOST back to the state of $(m .created):" "${comps[@]}") || return 1
    if grep -qx created <<<"$sel"; then
        local f list="$WORK/created.txt"
        grep -v "^$PVE_DIR/" "$created" >"$list"
        if [[ -s "$list" ]] && { d_text "Files to remove" "$list"; d_yesno "Undo" "Remove these $(wc -l <"$list") file(s)?" 7 50; }; then
            local netrm=0 rb=""
            grep -q '^/etc/network/' "$list" && { netrm=1; net_snapshot; rb=$REPLY; }
            COMMITTED=()
            while IFS= read -r f; do
                if (( DRY_RUN )); then note "[dry-run] would remove $f"; else rm -f -- "$f" && { CHANGES=$((CHANGES+1)); note "removed: $f"; COMMITTED+=("$f"); }; fi
            done <"$list"
            # follow-up commands for the removed files; values of removed sysctl/module files
            # stay active in the running kernel until the next boot
            post_hooks
            grep -qE '^/etc/(sysctl|modprobe|modules)' "$list" && { REBOOT_NEEDED=1; note "reboot needed: removed sysctl/module settings stay active until then"; }
            # removed interfaces files (e.g. a bridge) only go away with a reload
            (( netrm )) && apply_network "$rb"
        fi
    fi
    grep -qx network <<<"$sel" && restore_network
    grep -qx apt <<<"$sel" && restore_apt
    grep -qx system <<<"$sel" && restore_system
    grep -qx extra <<<"$sel" && restore_extra
    if grep -qx db <<<"$sel"; then
        local reboot=$REBOOT_NEEDED
        dr_swap_db || return 0
        REBOOT_NEEDED=$reboot   # same host name: the database alone needs no reboot
        (( DRY_RUN )) || [[ -z "$DB_BACKUP" ]] || note "database rolled back; the replaced one is $DB_BACKUP"
    fi
}

cmd_restore() {
    local file="" pwfile=""
    while (( $# )); do
        case "$1" in
            --dry-run|-n) DRY_RUN=1; shift ;;
            -p|--passphrase-file) pwfile=${2:?}; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) file=$1; shift ;;
        esac
    done
    preflight
    is_tty || die "restore needs an interactive terminal."
    IN_TUI=1
    need_cmds dialog:dialog diff:diffutils tar:tar zstd:zstd jq:jq sqlite3:sqlite3
    take_lock
    if [[ -z "$file" ]]; then file=$(pick_backup_file "Restore") || { clear; return 0; }; fi
    [[ -n "$pwfile" ]] && check_passfile "$pwfile"
    d_info "Restore" "Opening and verifying $(basename "$file") ..."
    open_archive "$file" "$pwfile"
    ARCHIVE_FILE=$(readlink -f "$file")
    if ! mountpoint -q "$PVE_DIR" && ! ensure_pve_running; then
        # typical for a damaged config.db: replacing the database is exactly the repair
        PMXCFS_UP=0
        d_msg "pve-cluster not running" "$PVE_DIR is not mounted (pve-cluster does not run, e.g. because its database is damaged).\n\nOnly the exact disaster recovery is possible: it replaces the database with the one from the backup." 12 72
    fi

    # same version is safest (config formats); a different major version is a hard warning
    local srcv curv warnv=""
    srcv=$(pve_ver "$(m .pve_version)"); curv=$(pve_ver "$(pveversion | awk '{print $1}')")
    if [[ -n "$srcv" && "${srcv%%.*}" != "${curv%%.*}" ]]; then
        warnv="\n\nWARNING: backup is from PVE $srcv, this host runs PVE $curv. Config formats differ; install the same major version first."
    elif [[ -n "$srcv" && "$srcv" != "$curv" ]]; then
        warnv="\n\nNote: backup PVE $srcv, this host PVE $curv. Best update both to the same version first."
    fi
    local ng; ng=$(jq -r '(.ids // {}) | length' "$PVE_DIR/.vmlist" 2>/dev/null || echo 0)
    local ceph=""; [[ -f "$P/ceph.conf" ]] && ceph="\n\nNote: Ceph is configured in the backup; Ceph is not restored by this tool."

    local def=migrate undo_item=()
    if [[ "$ng" == 0 && ! -f "$PVE_DIR/corosync.conf" ]]; then
        [[ "$CUR_HOST" == "$SRC_HOST" || -z "$(m .cluster_name)" ]] && def=dr
    fi
    if [[ "$SRC_HOST" == "$CUR_HOST" ]]; then
        undo_item=(undo "Undo: roll this host back to this backup")
        [[ "$ARCHIVE_FILE" == "$PRE_DIR"/* ]] && def=undo
    fi
    local mig_item=(migrate "Selective migration (take over chosen parts)")
    if (( ! PMXCFS_UP )); then def=dr; mig_item=(); undo_item=(); fi
    MODE=$(dialog --backtitle "$BACKTITLE" --title "Restore $(basename "$file")" --default-item "$def" --menu \
        "Backup : $SRC_HOST, $(m .created)\n         $(m .pve_version | awk '{print $1}')\n         cluster: $(m '.cluster_name // ""' | sed 's/^$/none/')\nThis   : $CUR_HOST, $(pveversion | awk '{print $1}')\n         $ng guest(s), $([[ -f $PVE_DIR/corosync.conf ]] && echo 'cluster member' || echo standalone)$warnv$ceph\n\nRestore mode:" \
        24 78 4 \
        dr "Full disaster recovery (fresh host becomes $SRC_HOST)" \
        "${mig_item[@]}" \
        "${undo_item[@]}" \
        3>&1 1>&2 2>&3) || { clear; return 0; }
    (( DRY_RUN )) && d_msg "Dry run" "Dry run: every step is shown, nothing is written or executed." 7 60
    if [[ "$MODE" != undo && "$MODE" != dr ]]; then
        not_restorable "$MODE" >"$WORK/notes.txt"
        d_text "Not restorable" "$WORK/notes.txt"
    fi

    # undo point
    if (( ! DRY_RUN )); then
        d_info "Restore" "Saving the current state to $PRE_DIR (undo point) ..."
        # in a subshell: a damaged database must not end the restore that is meant to repair it
        local out rc=0
        # the subshell cleans up only its own temp files, never the extracted archive of this run
        out=$( TMPDIRS=(); PASSFILE_TMP=""; trap cleanup EXIT; IN_TUI=; QUIET=0
               do_backup "$PRE_DIR" "$PRE_KEEP" "" 2>&1 ) || rc=$?
        if (( rc == 0 )); then
            UNDO_ARCHIVE=$(sed -n 's/^Backup written: \(.*\) (.*)$/\1/p' <<<"$out")
            note "undo point: $UNDO_ARCHIVE"
        else
            log "undo point failed: $out"
            d_noyes "Undo point" "The current state could not be saved:\n\n$(tail -2 <<<"$out")\n\nContinue WITHOUT an undo point?" 13 76 || die "Cancelled: no undo point."
            note "no undo point (backup of the current state failed)"
        fi
    fi
    OLD_NODE=$SRC_HOST
    case "$MODE" in
        dr) restore_dr ;;
        migrate) restore_migrate ;;
        undo) restore_undo ;;
    esac
    (( DRY_RUN )) || ensure_pve_running || true
    offer_disable_jobs
    # nothing changed (cancelled or declined): drop the undo point, it would only push older
    # undo points out of the rotation
    if (( ! CHANGES )) && [[ -n "$UNDO_ARCHIVE" ]]; then
        rm -f -- "$UNDO_ARCHIVE"
        note "nothing changed, undo point removed"
        UNDO_ARCHIVE=""
    fi
    # remember the files this restore created, for a later undo from the undo point
    if (( ! DRY_RUN )) && [[ -n "$UNDO_ARCHIVE" ]] && (( ${#CREATED[@]} )); then
        printf '%s\n' "${CREATED[@]}" >"$UNDO_ARCHIVE.created"
        chmod 600 "$UNDO_ARCHIVE.created"
    fi
    restore_summary
}

# After a restore the host may run the backup jobs of the source host. If the source is still
# running (test or parallel restore) both would write to the same backup storage.
offer_disable_jobs() {
    (( DRY_RUN )) && return 0
    [[ "$MODE" == dr || "$MODE" == migrate ]] || return 0   # select/undo: same host, nothing to ask
    (( JOBS_RESTORED )) || return 0                          # no jobs written by this run
    systemctl is-active -q pve-cluster || return 0
    local ids=() id items=() from_backup
    from_backup=$(sc_ids "$P/jobs.cfg" | awk '{print $2}')
    # active jobs that came from the backup (the host's own earlier jobs are left alone)
    mapfile -t ids < <(pvesh get /cluster/backup --output-format json 2>/dev/null \
        | jq -r '.[] | select((.enabled // 1) | tostring != "0") | .id' 2>/dev/null | grep -xF -f <(echo "$from_backup"))
    (( ${#ids[@]} )) || return 0
    for id in "${ids[@]}"; do items+=("$id" "" on); done
    d_noyes "Backup jobs" "${#ids[@]} backup job(s) are active on this host now.\n\nIf the original host $SRC_HOST is still running (test or parallel restore), disable them, otherwise both hosts back up to the same storage.\n\nDisable backup jobs now?" 13 72 || return 0
    local sel
    sel=$(d_check "Backup jobs" "Jobs to disable:" "${items[@]}") || return 0
    (umask 022; mkdir -p /var/lock/pve-manager)
    for id in $sel; do run_cmd pvesh set "/cluster/backup/$id" --enabled 0; done
}

restore_summary() {
    local out="$WORK/summary.txt"
    {
        echo "Restore mode: $MODE$( (( DRY_RUN )) && echo ' (dry run)')"
        echo "Source: $SRC_HOST   Target: $(hostname -s)"
        echo
        printf '%s\n' "${ACTIONS[@]}"
        echo
        echo "Log: $LOGFILE"
        (( ${#RESTORED_VMIDS[@]} )) && echo "Guest disks are not part of this backup: restore them from PBS if they do not exist."
        (( REBOOT_NEEDED )) && echo "A reboot is needed to apply all changes."
        if [[ "$(hostname -s)" != "$START_HOST" && -n "$DB_BACKUP" ]]; then
            # renamed by the recovery: the undo mode (same name only) does not apply
            echo "Undo: write '$START_HOST' back to /etc/hostname and /etc/hosts, then"
            echo "      systemctl stop pve-cluster; cp $DB_BACKUP $DB; reboot"
        else
            [[ -n "$UNDO_ARCHIVE" && "$MODE" != undo ]] && echo "Undo of this restore: $PROG restore $UNDO_ARCHIVE  (mode Undo)"
            [[ -n "$DB_BACKUP" && "$MODE" == undo ]] && echo "Undo of this undo: systemctl stop pve-cluster; cp $DB_BACKUP $DB; reboot"
        fi
    } >"$out"
    log "restore summary:"; cat "$out" >>"$LOGFILE"
    d_text "Restore finished" "$out"
    if (( REBOOT_NEEDED && ! DRY_RUN )) && d_noyes "Reboot" "Reboot now?" 7 40; then
        clear; systemctl reboot; exit 0
    fi
    clear
    cat "$out"
}

# ===========================================================================
# Schedule (cron)
# ===========================================================================
cron_line() { grep -E '^[^#].* root ' "$CRON_FILE" 2>/dev/null | head -1; }

cmd_schedule() {
    preflight
    is_tty || die "schedule needs an interactive terminal."
    IN_TUI=1
    need_cmds dialog:dialog
    local cur choice
    while :; do
        cur=$(cron_line)
        choice=$(d_menu "Scheduled backup" "Current cron job:\n  ${cur:-none}" \
            set "create / change the schedule" \
            remove "remove the schedule" \
            run "run the scheduled backup now" \
            back "back") || return 0
        case "$choice" in
            set) schedule_set ;;
            remove)
                if [[ -f "$CRON_FILE" ]] && d_yesno "Remove" "Remove $CRON_FILE?" 7 60; then
                    rm -f "$CRON_FILE"; log "schedule removed"
                fi ;;
            run)
                [[ -n "$cur" ]] || { d_msg "Run" "No schedule configured." 7 40; continue; }
                local cmdl rc=0
                cmdl=$(sed -E 's/^([^ ]+ +){5}root +//' <<<"$cur")
                d_info "Run" "Running: $cmdl"
                bash -c "$cmdl" >"$LOCK_FILE.out" 2>&1 </dev/null || rc=$?
                d_msg "Run" "Exit code $rc\n\n$(tail -5 "$LOCK_FILE.out")" 12 76
                rm -f "$LOCK_FILE.out" ;;
            back) return 0 ;;
        esac
    done
}

schedule_set() {
    local when expr dir keep enc pwfile="" line self
    when=$(d_menu "Schedule" "When should the backup run?" \
        daily "every day at 02:30" \
        weekly "every Sunday at 02:30" \
        custom "own cron expression") || return 0
    case "$when" in
        daily) expr="30 2 * * *" ;;
        weekly) expr="30 2 * * 0" ;;
        custom)
            expr=$(d_input "Schedule" "Cron expression (minute hour day month weekday):" "30 2 * * *") || return 0
            [[ "$expr" =~ ^[0-9*/,-]+\ [0-9*/,-]+\ [0-9*/,-]+\ [0-9*/,-]+\ [0-9*/,-]+$ ]] \
                || { d_msg "Schedule" "Invalid cron expression." 7 50; return 0; } ;;
    esac
    dir=$(d_input "Backup directory" "Target directory. Use storage that survives a host failure (NFS/CIFS mount, other disk):" "$DEFAULT_DIR") || return 0
    [[ "$dir" == /* ]] || { d_msg "Schedule" "Please give an absolute path." 7 50; return 0; }
    [[ "$dir" =~ [[:space:]%] ]] && { d_msg "Schedule" "The path must not contain spaces or %." 7 50; return 0; }
    keep=$(d_input "Retention" "Number of backups of this host to keep in $dir (0 = keep all):" "$DEFAULT_KEEP") || return 0
    [[ "$keep" =~ ^[0-9]+$ ]] || { d_msg "Schedule" "Not a number." 7 40; return 0; }
    on_root_fs "$dir" && d_msg "Note" "$dir is on the root filesystem of this host. Copy the backups elsewhere, otherwise they are lost together with the host." 9 70
    if d_noyes "Encryption" "Encrypt the backups with a passphrase?\n\nThe passphrase is stored in a root-only file for cron. Keep a copy of it outside this host, without it the backups cannot be restored." 11 72; then
        pwfile=$(d_input "Passphrase file" "File holding the passphrase (created if missing):" "/root/.pve-config-backup.pass") || return 0
        if [[ ! -s "$pwfile" ]]; then
            ask_new_passphrase || return 0
            install -m 600 -o root -g root "$REPLY" "$pwfile" || { d_msg "Error" "Cannot write $pwfile." 7 50; return 0; }
        fi
        check_passfile "$pwfile"
    fi
    local copy="" cur_to p
    read -r cur_to p <<<"$(saved_target)"; SSH_PORT=${p:-22}
    if d_noyes "Copy via SSH" "Also copy every backup to another host via SSH?\n\nThe backup then survives a failure of this host. A dedicated key is used that can only write into one directory on the target.${cur_to:+\n\nCurrent target: $cur_to}" 13 72; then
        ssh_setup "$cur_to" || return 0
        printf '%s %s\n' "$COPY_TO" "$SSH_PORT" >"$SSH_CONF"; chmod 600 "$SSH_CONF"
        copy=" --copy-to $COPY_TO"
        (( SSH_PORT != 22 )) && copy+=" --ssh-port $SSH_PORT"
        if [[ -z "$pwfile" ]]; then
            d_noyes "Copy via SSH" "The backups are NOT encrypted, but they hold passwords, token secrets and keys. Anyone with access to the target could read them.\n\nCopy them unencrypted anyway?" 11 72 || return 0
            copy+=" --copy-unencrypted"
        fi
        need_cmds rsync:rsync
    fi
    # the cron job runs without a terminal and cannot ask for missing tools
    need_cmds tar:tar zstd:zstd sqlite3:sqlite3 jq:jq
    [[ -n "$pwfile" ]] && need_cmds gpg:gpg
    self=$(readlink -f "$0")
    if [[ "$self" != "$INSTALL_PATH" ]]; then
        install -m 755 "$self" "$INSTALL_PATH" || { d_msg "Error" "Cannot install to $INSTALL_PATH." 7 50; return 0; }
    fi
    line="$expr root $INSTALL_PATH backup -o $dir -k $keep${pwfile:+ -p $pwfile}$copy -q"
    cat >"$CRON_FILE" <<EOF
# $PROG: managed by '$PROG schedule'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$line
EOF
    chmod 644 "$CRON_FILE"
    log "schedule set: $line"
    d_msg "Schedule" "Written $CRON_FILE:\n\n$line\n\nThe script was installed to $INSTALL_PATH. Errors are mailed by cron to root and logged to $LOGFILE." 13 78
}

# ===========================================================================
# Interactive menu
# ===========================================================================
pick_backup_file() { # title -> path
    local title=$1 files=() opts=() f dirs=("$DEFAULT_DIR" "$PRE_DIR")
    # also the target directory of the cron job, if one is set up
    f=$(cron_line | sed -nE 's/.* -o ([^ ]+).*/\1/p'); [[ -n "$f" && "$f" != "$DEFAULT_DIR" ]] && dirs+=("$f")
    mapfile -t files < <(find "${dirs[@]}" -maxdepth 1 -type f \( -name 'pvecfg_*.tar.zst' -o -name 'pvecfg_*.tar.zst.gpg' \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    local i
    for i in "${!files[@]}"; do
        f=${files[$i]}
        opts+=("$((i+1))" "${f##*/}  $(numfmt --to=iec "$(stat -c %s "$f")")$([[ $f == "$PRE_DIR"/* ]] && echo '  (undo point)')")
    done
    opts+=(0 "enter a path ...")
    i=$(d_menu "$title" "Choose a backup file:" "${opts[@]}") || return 1
    if [[ "$i" == 0 ]]; then
        f=$(d_input "$title" "Path of the backup file:" "$DEFAULT_DIR/") || return 1
    else
        f=${files[$((i-1))]}
    fi
    [[ -f "$f" ]] || { d_msg "$title" "$f not found." 7 60; return 1; }
    printf '%s' "$f"
}

tui_backup() {
    local dir keep pwfile=""
    dir=$(d_input "Backup" "Target directory:" "$DEFAULT_DIR") || return 0
    keep=$(d_input "Backup" "Keep how many backups of this host in $dir (0 = all):" "$DEFAULT_KEEP") || return 0
    [[ "$keep" =~ ^[0-9]+$ ]] || { d_msg "Backup" "Not a number." 7 40; return 0; }
    if d_noyes "Backup" "Encrypt the backup with a passphrase?" 7 50; then
        ask_new_passphrase || return 0
        pwfile=$REPLY
    fi
    local cur_to copied="" p
    read -r cur_to p <<<"$(saved_target)"; SSH_PORT=${p:-22}
    COPY_TO=""
    if d_noyes "Backup" "Also copy the backup to another host via SSH?${cur_to:+\n\n(saved target: $cur_to)}" 9 72; then
        ssh_setup "$cur_to" || return 0
        printf '%s %s\n' "$COPY_TO" "$SSH_PORT" >"$SSH_CONF"; chmod 600 "$SSH_CONF"
        if [[ -z "$pwfile" ]]; then
            d_noyes "Copy via SSH" "This backup is NOT encrypted, but it holds passwords, token secrets and keys.\n\nCopy it unencrypted anyway?" 10 72 || COPY_TO=""
        fi
    fi
    d_info "Backup" "Creating the backup ..."
    local saved_quiet=$QUIET; QUIET=1
    do_backup "$dir" "$keep" "$pwfile"
    if [[ -n "$COPY_TO" ]]; then
        d_info "Backup" "Copying to $COPY_TO ..."
        if copy_remote "$BACKUP_RESULT" >/dev/null 2>&1; then copied="\n\nCopied to $COPY_TO"
        else copied="\n\nCOPY TO $COPY_TO FAILED, see $LOGFILE"; fi
    fi
    QUIET=$saved_quiet
    local hint=""
    on_root_fs "$dir" && [[ -z "$copied" ]] && hint="\n\nNote: the directory is on this host's root filesystem. Copy the file elsewhere."
    d_msg "Backup" "Backup written:\n\n$BACKUP_RESULT\n$(numfmt --to=iec "$(stat -c %s "$BACKUP_RESULT")")$copied$hint" 14 78
    [[ -n "$PASSFILE_TMP" ]] && { rm -f "$PASSFILE_TMP"; PASSFILE_TMP=""; }
}

main_menu() {
    preflight
    is_tty || { usage; exit 1; }
    IN_TUI=1
    need_cmds dialog:dialog
    local c f
    while :; do
        c=$(d_menu "$PROG on $CUR_HOST" "Back up and restore the Proxmox VE host configuration." \
            backup "create a backup now" \
            restore "restore from a backup" \
            dryrun "restore, dry run (show only)" \
            inspect "show the contents of a backup" \
            schedule "scheduled backup (cron)" \
            include "own files and folders to back up" \
            ssh "copy backups to another host (SSH)" \
            check "check / start the Proxmox VE services" \
            quit "exit") || { clear; exit 0; }
        case "$c" in
            backup) take_lock; tui_backup; flock -u 9 ;;
            restore) clear; exec "$(readlink -f "$0")" restore ;;
            dryrun) clear; exec "$(readlink -f "$0")" restore --dry-run ;;
            inspect) f=$(pick_backup_file "Inspect") && ( TMPDIRS=(); PASSFILE_TMP=""; trap cleanup EXIT; cmd_inspect "$f" ) ;;
            schedule) cmd_schedule ;;
            include) edit_includes ;;
            ssh) ssh_menu ;;
            check) if ensure_pve_running; then d_msg "Proxmox VE services" "All services run, /etc/pve is mounted and the API answers." 8 64; fi ;;
            quit) clear; exit 0 ;;
        esac
    done
}

# edit the include list; every backup (also the cron job) reads it
edit_includes() {
    local tmp
    tmp=$(mktemp /var/tmp/pve-config-backup.include.XXXXXX) || return 0
    if [[ -f "$INCLUDE_FILE" ]]; then cp "$INCLUDE_FILE" "$tmp"
    else printf '%s\n' "# Own files and folders for $PROG, one absolute path per line." \
        "# Globs are allowed (/opt/scripts/*.sh). Backed up by every run, also the cron job;" \
        "# restored only when chosen. Example:" "# /opt/my-scripts" >"$tmp"; fi
    if d_edit "$INCLUDE_FILE" "$tmp"; then
        install -m 644 "$tmp" "$INCLUDE_FILE" && log "include list changed"
        local list; list=$(extra_paths 2>/dev/null); list=${list//$'\n'/\\n  }
        d_msg "Own files and folders" "Backed up from now on:\n\n  ${list:-(nothing)}" 16 76
    fi
    rm -f -- "$tmp" "$tmp.edit"
}

usage() {
    sed -n '/^# Usage:/,/^# Requires:/p' "$(readlink -f "$0")" | sed 's/^# \{0,1\}//' | sed '$d'
}

main() {
    local cmd=${1:-}
    [[ $# -gt 0 ]] && shift
    case "$cmd" in
        backup) cmd_backup "$@" ;;
        restore) cmd_restore "$@" ;;
        inspect) cmd_inspect "$@" ;;
        schedule) cmd_schedule ;;
        "") main_menu ;;
        -h|--help|help) usage ;;
        -V|--version) echo "$PROG $VERSION" ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
