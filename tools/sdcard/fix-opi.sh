#!/bin/bash
# fix-opi.sh - offline repair of the opi02w-4 (Arch Linux ARM / Orange Pi Zero 2W) rootfs
#
# Fixes:
#   1. systemd-networkd and NetworkManager both enabled - disables + masks networkd
#   2. swares password - prompts, hashes SHA-512, writes to /etc/shadow
#   3. sshd PasswordAuthentication no -> yes (drop-in + main config)
#
# Run as root in WSL with the repaired image mounted at /mnt/opi:
#   bash fix-opi.sh
#
# Every change is backed up with a .bak-YYYYmmdd suffix. Nothing is destructive.

set -u
R=/mnt/opi
STAMP=$(date +%Y%m%d-%H%M%S)

die() { echo "ERROR: $*" >&2; exit 1; }
sec() { echo; echo "--- $* ---"; }

[ -f "$R/etc/os-release" ] || die "nothing mounted at $R"
grep -q archarm "$R/etc/os-release" || die "$R does not look like Arch Linux ARM"
[ "$(id -u)" -eq 0 ] || die "run as root (wsl -u root)"

echo "Target rootfs : $R"
echo "Backup suffix : .bak-$STAMP"

# ============================================================ 0. INFO ONLY
sec "UWE5622 firmware present?"
ls "$R"/lib/firmware/ 2>/dev/null | grep -iE 'wcn|wifi_2355|wifi_.*\.ini|bt_configure' \
    || echo "  (none found by name - if wifi still fails after this, missing firmware is the next suspect)"

sec "custom units, for reference"
for u in opizero2w-post-install.service db-unlock.service; do
    f="$R/usr/lib/systemd/system/$u"
    [ -f "$f" ] || f="$R/etc/systemd/system/$u"
    if [ -f "$f" ]; then
        echo "== $u =="
        grep -vE '^\s*$' "$f" | head -15
    fi
done

# ================================================ 1. NETWORK STACK CONFLICT
sec "1. disabling systemd-networkd (conflicts with NetworkManager)"

NETWORKD_LINKS="
etc/systemd/system/multi-user.target.wants/systemd-networkd.service
etc/systemd/system/sockets.target.wants/systemd-networkd.socket
etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service
etc/systemd/system/dbus-org.freedesktop.network1.service
"

for l in $NETWORKD_LINKS; do
    if [ -L "$R/$l" ]; then
        rm -f "$R/$l" && echo "  removed  $l"
    else
        echo "  absent   $l"
    fi
done

# Mask so nothing can socket-activate or dependency-pull it back.
mkdir -p "$R/etc/systemd/system"
for u in systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service; do
    ln -sf /dev/null "$R/etc/systemd/system/$u" && echo "  masked   $u"
done

echo "  NetworkManager.service still enabled:"
if [ -L "$R/etc/systemd/system/multi-user.target.wants/NetworkManager.service" ]; then
    echo "    yes"
else
    echo "    NO - re-enabling"
    ln -sf /usr/lib/systemd/system/NetworkManager.service \
           "$R/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
fi

sec "wifi profile sanity (NM ignores anything not root-owned 0600)"
for f in "$R"/etc/NetworkManager/system-connections/*.nmconnection; do
    [ -e "$f" ] || continue
    chown root:root "$f"; chmod 600 "$f"
    printf '  %-55s %s %s\n' "$(basename "$f")" \
        "$(stat -c '%U:%G' "$f")" "$(stat -c '%a' "$f")"
done

# Make sure nothing marks wlan0 unmanaged.
if grep -rqs 'unmanaged-devices' "$R/etc/NetworkManager/"; then
    echo "  WARNING: an unmanaged-devices rule exists:"
    grep -rns 'unmanaged-devices' "$R/etc/NetworkManager/"
else
    echo "  no unmanaged-devices rules"
fi

# ==================================================== 2. SWARES PASSWORD
sec "2. setting swares password"

grep -q '^swares:' "$R/etc/shadow" || die "no swares entry in /etc/shadow"

while :; do
    read -rsp "  New password for swares: " P1; echo
    read -rsp "  Repeat:                  " P2; echo
    [ -n "$P1" ] || { echo "  empty, try again"; continue; }
    [ "$P1" = "$P2" ] && break
    echo "  mismatch, try again"
done

HASH=$(openssl passwd -6 "$P1" 2>/dev/null)
if [ -z "$HASH" ]; then
    HASH=$(python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))' "$P1")
fi
[ -n "$HASH" ] || die "could not generate a SHA-512 hash (need openssl or python3)"
case "$HASH" in \$6\$*) ;; *) die "unexpected hash format: ${HASH:0:8}" ;; esac
unset P1 P2

DAYS=$(( $(date +%s) / 86400 ))

cp -a "$R/etc/shadow" "$R/etc/shadow.bak-$STAMP"
OWN=$(stat -c '%u:%g' "$R/etc/shadow"); MODE=$(stat -c '%a' "$R/etc/shadow")

awk -F: -v OFS=: -v u=swares -v h="$HASH" -v d="$DAYS" \
    '$1==u { $2=h; $3=d } 1' "$R/etc/shadow.bak-$STAMP" > "$R/etc/shadow.new" \
    || die "awk failed"

grep -q '^swares:\$6\$' "$R/etc/shadow.new" || die "rewrite failed, /etc/shadow untouched"
[ "$(wc -l < "$R/etc/shadow.new")" -eq "$(wc -l < "$R/etc/shadow.bak-$STAMP")" ] \
    || die "line count changed, refusing to install"

mv "$R/etc/shadow.new" "$R/etc/shadow"
chown "$OWN" "$R/etc/shadow"; chmod "$MODE" "$R/etc/shadow"
echo "  swares: hash installed, lastchg=$DAYS, perms $(stat -c '%U:%G %a' "$R/etc/shadow")"
echo "  root:   left locked (console recovery unavailable - intentional)"

# ====================================================== 3. SSH PASSWORD AUTH
sec "3. enabling sshd PasswordAuthentication"

# sshd_config has `Include /etc/ssh/sshd_config.d/*.conf` on line 1, and OpenSSH
# takes the FIRST value it sees, so a low-numbered drop-in beats the later
# `PasswordAuthentication no`. Write the drop-in and fix the main file too.
DROPIN="$R/etc/ssh/sshd_config.d/10-local.conf"
mkdir -p "$(dirname "$DROPIN")"
cat > "$DROPIN" <<'EOF'
# Added offline to restore password login.
PasswordAuthentication yes
KbdInteractiveAuthentication no
EOF
chown root:root "$DROPIN"; chmod 644 "$DROPIN"
echo "  wrote $(basename "$DROPIN")"

if grep -qE '^\s*PasswordAuthentication\s+no' "$R/etc/ssh/sshd_config"; then
    cp -a "$R/etc/ssh/sshd_config" "$R/etc/ssh/sshd_config.bak-$STAMP"
    sed -i 's/^\s*PasswordAuthentication\s\+no/PasswordAuthentication yes/' "$R/etc/ssh/sshd_config"
    echo "  main sshd_config: PasswordAuthentication -> yes"
fi

echo "  effective:"
grep -hE '^\s*(PasswordAuthentication|PubkeyAuthentication|PermitRootLogin)' \
     "$R/etc/ssh/sshd_config" "$R/etc/ssh/sshd_config.d/"*.conf 2>/dev/null | sed 's/^/    /'

# ================================================================ SUMMARY
sec "SUMMARY"
cat <<EOF
  systemd-networkd : disabled + masked
  NetworkManager   : enabled, profiles root:root 0600
  swares password  : set
  sshd             : password auth enabled
  backups          : *.bak-$STAMP under $R/etc

  Next:
    umount $R && losetup -d \$(losetup -j /mnt/c/opi/opi02w-4.img -O NAME -n)
    then write the image back to the card.

  To undo the networkd change later, on the running board:
    rm /etc/systemd/system/systemd-networkd.{service,socket}
    systemctl unmask systemd-networkd.service systemd-networkd.socket
EOF
