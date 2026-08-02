#!/bin/bash
# prep-armbian.sh - preconfigure an Armbian image for unattended headless first boot
#
#   bash prep-armbian.sh /mnt/c/opi/Armbian_xx_Orangepizero2w_trixie_minimal.img [authorized_keys]
#
# The Orange Pi Zero 2W has no ethernet, so if wifi is not configured before the
# first boot the board comes up unreachable. This writes the wifi credentials,
# root password and user account into the image while it is still a file.
#
# Detects which first-run mechanism the image ships and only writes preset
# variables that the image's own firstlogin script actually reads.

set -u
IMG="${1:-}"
KEYS="${2:-}"
M=/mnt/armbian
HOSTNAME_NEW=opi02w-4

die() { echo "ERROR: $*" >&2; cleanup; exit 1; }
sec() { echo; echo "--- $* ---"; }

LOOP=""
cleanup() {
    mountpoint -q "$M/boot" 2>/dev/null && umount "$M/boot"
    mountpoint -q "$M"      2>/dev/null && umount "$M"
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    return 0
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die "run as root (wsl -u root)"
[ -n "$IMG" ] || die "usage: prep-armbian.sh <image.img> [authorized_keys]"
[ -f "$IMG" ] || die "no such image: $IMG"

case "$IMG" in
    *.xz|*.gz|*.zip) die "decompress first: unxz '$IMG'" ;;
esac

# ------------------------------------------------ attach + find rootfs
sec "attaching image"
for old in $(losetup -j "$IMG" -O NAME -n 2>/dev/null); do
    echo "  detaching stale $old"; umount "$old"* 2>/dev/null; losetup -d "$old" 2>/dev/null
done

LOOP=$(losetup -fP --show "$IMG") || die "losetup failed"
echo "  $IMG -> $LOOP"
sleep 1
lsblk -o NAME,SIZE,FSTYPE,LABEL "$LOOP" 2>/dev/null | sed 's/^/  /'

ROOTPART=$(lsblk -rno NAME,FSTYPE "$LOOP" 2>/dev/null | awk '$2=="ext4"{print "/dev/"$1; exit}')
[ -n "$ROOTPART" ] || die "no ext4 partition found in image"
echo "  rootfs: $ROOTPART"

mkdir -p "$M"
mount "$ROOTPART" "$M" || die "mount failed"

# Orange Pi images put /boot on a separate FAT partition. If we don't mount it,
# anything written to $M/boot lands in an empty stub directory and is lost.
BOOTPART=$(lsblk -rno NAME,FSTYPE "$LOOP" 2>/dev/null | awk '$2 ~ /^v?fat/{print "/dev/"$1; exit}')
if [ -n "$BOOTPART" ]; then
    mkdir -p "$M/boot"
    if mount "$BOOTPART" "$M/boot"; then
        echo "  boot partition: $BOOTPART -> $M/boot"
    else
        echo "  WARNING: could not mount $BOOTPART"
    fi
fi
REL=""
for c in "$M/etc/armbian-release" "$M/etc/orangepi-release"; do
    [ -f "$c" ] && REL="$c" && break
done
if [ -n "$REL" ]; then
    echo "  release file: ${REL#$M}"
    grep -E '^(BOARD|VERSION|BRANCH|RELEASE|LINUXFAMILY)=' "$REL" | sed 's/^/  /'
else
    echo "  WARNING: no armbian-release or orangepi-release found"
fi
grep -E '^PRETTY_NAME=' "$M/etc/os-release" | sed 's/^/  /'

# ---------------------------------------- HARD GATE: wifi driver must exist
# The Zero 2W's UWE5622 has no mainline driver. Armbian 'current' images build
# fine and boot fine and then sit there with no network and no ethernet port to
# recover through. Refuse to prepare an image that cannot bring up wlan0.
sec "wifi driver gate (UWE5622)"
UWE_MODS=$(find "$M/lib/modules" \( -iname '*uwe*' -o -iname '*sprdwl*' -o -iname '*sprdbt*' \) 2>/dev/null | head -5)
UWE_FW=$(ls "$M/lib/firmware/" 2>/dev/null | grep -iE 'wcnmodem|wifi_2355|wcn_' | head -5)

if [ -n "$UWE_MODS" ]; then
    echo "  modules found:"; echo "$UWE_MODS" | sed "s|$M||; s/^/    /"
else
    echo "  NO uwe5622/sprdwl modules in this image"
fi
if [ -n "$UWE_FW" ]; then
    echo "  firmware found:"; echo "$UWE_FW" | sed 's/^/    /'
else
    echo "  NO wcnmodem/wifi_2355 firmware in this image"
fi

if [ -z "$UWE_MODS" ]; then
    echo
    echo "  This board has no ethernet. Without the UWE5622 driver it will boot"
    echo "  unreachable. Use a BSP 6.1.x image (Xunlong official Debian/Ubuntu),"
    echo "  or set ALLOW_NO_WIFI=1 if you have console access and know what you're doing."
    [ "${ALLOW_NO_WIFI:-0}" = "1" ] || die "refusing to prepare an image with no wifi driver"
    echo "  ALLOW_NO_WIFI=1 set - continuing anyway"
fi

# ------------------------------------------------ detect mechanisms
sec "detecting first-run mechanisms"

# Orange Pi ships Armbian forks with everything renamed, so check both families.
FIRSTLOGIN=""
for c in "$M/usr/lib/armbian/armbian-firstlogin"   "$M/usr/bin/armbian-firstlogin" \
         "$M/usr/lib/orangepi/orangepi-firstlogin" "$M/usr/bin/orangepi-firstlogin"; do
    [ -f "$c" ] && FIRSTLOGIN="$c" && break
done

FIRSTRUN_TPL=""
for c in "$M/boot/armbian_first_run.txt.template"  "$M/boot/armbian_first_run.txt" \
         "$M/boot/orangepi_first_run.txt.template" "$M/boot/orangepi_first_run.txt"; do
    [ -f "$c" ] && FIRSTRUN_TPL="$c" && break
done

# Some forks use FR_* in the template but a different prefix; report what we see.
[ -n "$FIRSTRUN_TPL" ] && echo "  template vars: $(grep -ohE '^[A-Za-z_]+=' "$FIRSTRUN_TPL" | tr -d '=' | tr '\n' ' ')"

echo "  firstlogin script : ${FIRSTLOGIN:-NOT FOUND}"
echo "  first_run template: ${FIRSTRUN_TPL:-NOT FOUND}"

SUPPORTED=""
if [ -n "$FIRSTLOGIN" ]; then
    SUPPORTED=$(grep -ohE '\bPRESET_[A-Z0-9_]+' "$FIRSTLOGIN" | sort -u)
    echo "  PRESET_ variables this image understands:"
    echo "$SUPPORTED" | sed 's/^/    /'
fi

[ -n "$FIRSTLOGIN" ] || [ -n "$FIRSTRUN_TPL" ] || \
    die "neither mechanism present; do not flash blind - report this back"

# ------------------------------------------------ gather settings
sec "settings"

read -rp "  Wifi SSID [Linksys_5G]: " SSID; SSID=${SSID:-Linksys_5G}
while :; do
    read -rsp "  Wifi passphrase: " PSK; echo
    [ ${#PSK} -ge 8 ] && break
    echo "    WPA passphrases are at least 8 characters"
done
read -rp "  Wifi country code (regulatory domain, needed for 5 GHz) [US]: " CC; CC=${CC:-US}
read -rp "  Timezone [America/New_York]: " TZ; TZ=${TZ:-America/New_York}
read -rp "  Non-root username [swares]: " UNAME; UNAME=${UNAME:-swares}

while :; do
    read -rsp "  root password: " RPW; echo
    read -rsp "  repeat:        " RPW2; echo
    [ -n "$RPW" ] && [ "$RPW" = "$RPW2" ] && break
    echo "    empty or mismatch"
done
while :; do
    read -rsp "  $UNAME password: " UPW; echo
    read -rsp "  repeat:          " UPW2; echo
    [ -n "$UPW" ] && [ "$UPW" = "$UPW2" ] && break
    echo "    empty or mismatch"
done

[ -f "$M/usr/share/zoneinfo/$TZ" ] || echo "  WARNING: unknown timezone $TZ"

# ------------------------------------------------ network first-run
if [ -n "$FIRSTRUN_TPL" ]; then
    # Derive the runtime filename from the template so this works for both
    # armbian_first_run.txt.template and orangepi_first_run.txt.template.
    # Writing the wrong name means the network config is silently ignored.
    OUT="${FIRSTRUN_TPL%.template}"
    sec "writing ${OUT#$M}"
    sed -e "s|^FR_general_delete_this_file_after_completion=.*|FR_general_delete_this_file_after_completion=1|" \
        -e "s|^FR_net_change_defaults=.*|FR_net_change_defaults=1|" \
        -e "s|^FR_net_ethernet_enabled=.*|FR_net_ethernet_enabled=0|" \
        -e "s|^FR_net_wifi_enabled=.*|FR_net_wifi_enabled=1|" \
        -e "s|^FR_net_wifi_ssid=.*|FR_net_wifi_ssid='$SSID'|" \
        -e "s|^FR_net_wifi_key=.*|FR_net_wifi_key='$PSK'|" \
        -e "s|^FR_net_wifi_countrycode=.*|FR_net_wifi_countrycode='$CC'|" \
        "$FIRSTRUN_TPL" > "$OUT"
    chmod 644 "$OUT"
    grep -E '^FR_net' "$OUT" | sed -e "s|$PSK|********|" -e 's/^/  /'
fi

# ------------------------------------------------ account presets
if [ -n "$FIRSTLOGIN" ]; then
    sec "writing /root/.not_logged_in_yet"
    NLY="$M/root/.not_logged_in_yet"
    : > "$NLY"

    emit() {  # emit VAR value - only if the firstlogin script reads it
        if echo "$SUPPORTED" | grep -qx "$1"; then
            printf "%s='%s'\n" "$1" "$2" >> "$NLY"
            PRESETS_USED=1
            case "$1" in
                *PASSWORD*|*KEY*) echo "  $1='********'" ;;
                *) echo "  $1='$2'" ;;
            esac
        else
            echo "  (skipped $1 - not read by this image)"
        fi
    }

    emit PRESET_NET_CHANGE_DEFAULTS 1
    emit PRESET_NET_ETHERNET_ENABLED 0
    emit PRESET_NET_WIFI_ENABLED 1
    emit PRESET_NET_WIFI_SSID "$SSID"
    emit PRESET_NET_WIFI_KEY "$PSK"
    emit PRESET_NET_WIFI_COUNTRYCODE "$CC"
    emit PRESET_CONNECT_WIRELESS 1
    emit PRESET_ROOT_PASSWORD "$RPW"
    emit PRESET_USER_NAME "$UNAME"
    emit PRESET_USER_PASSWORD "$UPW"
    emit PRESET_DEFAULT_REALNAME "scott wares"
    emit PRESET_USER_SHELL bash
    emit PRESET_LOCALE "en_US.UTF-8"
    emit PRESET_TIMEZONE "$TZ"
    emit SET_LANG_BASED_ON_LOCATION n

    chown 0:0 "$NLY"; chmod 600 "$NLY"
fi

# ------------------------------------------- NetworkManager profile (always)
# Do NOT rely on the vendor first-run mechanism. On Orange Pi 1.0.2 images,
# orangepi-firstrun.service already ran on Xunlong's build machine and removed
# its own enablement symlink, so /boot/orangepi_first_run.txt is never read on
# the user's first boot. Writing the NM keyfile directly always works.
sec "writing NetworkManager profile for $SSID"

NMDIR="$M/etc/NetworkManager/system-connections"
if [ -d "$M/etc/NetworkManager" ]; then
    mkdir -p "$NMDIR"
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    PROFILE="$NMDIR/${SSID}.nmconnection"

    cat > "$PROFILE" <<EOF
[connection]
id=$SSID
uuid=$UUID
type=wifi
interface-name=wlan0
autoconnect=true
autoconnect-priority=10

[wifi]
mode=infrastructure
ssid=$SSID
# 2 = disable. The UWE5622 driver defaults to powersave on, which parks the
# radio and drops the first packet after idle - a wifi-only node then shows up
# as intermittently unreachable in health checks.
powersave=2

[wifi-security]
key-mgmt=wpa-psk
psk=$PSK

[ipv4]
method=auto

[ipv6]
addr-gen-mode=stable-privacy
method=auto

[proxy]
EOF

    # NetworkManager silently ignores keyfiles that are not root-owned 0600.
    chown 0:0 "$PROFILE"; chmod 600 "$PROFILE"
    printf '  %s  %s %s\n' "$(basename "$PROFILE")" \
        "$(stat -c '%U:%G' "$PROFILE")" "$(stat -c '%a' "$PROFILE")"

    # Regulatory domain - without it the driver will not use most 5 GHz channels.
    if [ -f "$M/etc/default/crda" ]; then
        sed -i "s/^REGDOMAIN=.*/REGDOMAIN=$CC/" "$M/etc/default/crda"
    else
        echo "REGDOMAIN=$CC" > "$M/etc/default/crda"
    fi
    echo "  regulatory domain: $CC"

    if grep -rqs 'unmanaged-devices' "$M/etc/NetworkManager/"; then
        echo "  WARNING: an unmanaged-devices rule exists and may block wlan0:"
        grep -rns 'unmanaged-devices' "$M/etc/NetworkManager/"
    fi
else
    echo "  no /etc/NetworkManager in image - skipping (image may use netplan/networkd)"
fi

# ------------------------------- offline accounts (when presets unsupported)
# Orange Pi's orangepi-firstlogin reads no PRESET_ variables, so the passwords
# collected above would be silently discarded. Write them into /etc/shadow
# directly and create the user by hand instead.
if [ "${PRESETS_USED:-0}" != "1" ]; then
    sec "no preset support - configuring accounts offline"

    mkhash() {
        local h
        h=$(openssl passwd -6 "$1" 2>/dev/null) || true
        [ -z "$h" ] && h=$(python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))' "$1" 2>/dev/null)
        case "$h" in \$6\$*) printf '%s' "$h" ;; *) return 1 ;; esac
    }

    setpw() {  # setpw <user> <hash>
        local u=$1 h=$2 own mode
        own=$(stat -c '%u:%g' "$M/etc/shadow"); mode=$(stat -c '%a' "$M/etc/shadow")
        awk -F: -v OFS=: -v u="$u" -v h="$h" -v d="$DAYS" \
            '$1==u { $2=h; $3=d } 1' "$M/etc/shadow" > "$M/etc/shadow.new" || return 1
        grep -q "^$u:\\\$6\\\$" "$M/etc/shadow.new" || { rm -f "$M/etc/shadow.new"; return 1; }
        mv "$M/etc/shadow.new" "$M/etc/shadow"
        chown "$own" "$M/etc/shadow"; chmod "$mode" "$M/etc/shadow"
    }

    DAYS=$(( $(date +%s) / 86400 ))
    cp -a "$M/etc/shadow" "$M/etc/shadow.bak-prep"

    RHASH=$(mkhash "$RPW") || die "could not hash root password"
    setpw root "$RHASH" && echo "  root: password set" || die "failed to set root password"

    # --- create the non-root user ---
    if grep -q "^$UNAME:" "$M/etc/passwd"; then
        UHASH=$(mkhash "$UPW") || die "could not hash user password"
        setpw "$UNAME" "$UHASH" && echo "  $UNAME: existed, password set"
        UID_N=$(awk -F: -v u="$UNAME" '$1==u{print $3}' "$M/etc/passwd")
    else
        UID_N=1000
        while awk -F: -v i="$UID_N" '$3==i{f=1} END{exit !f}' "$M/etc/passwd"; do
            UID_N=$((UID_N+1))
        done
        UHASH=$(mkhash "$UPW") || die "could not hash user password"

        printf '%s:x:%s:%s:%s:/home/%s:/bin/bash\n' \
               "$UNAME" "$UID_N" "$UID_N" "scott wares" "$UNAME" >> "$M/etc/passwd"
        printf '%s:x:%s:\n' "$UNAME" "$UID_N" >> "$M/etc/group"
        printf '%s:%s:%s:0:99999:7:::\n' "$UNAME" "$UHASH" "$DAYS" >> "$M/etc/shadow"
        printf '%s:!::\n' "$UNAME" >> "$M/etc/gshadow" 2>/dev/null || true

        mkdir -p "$M/home/$UNAME"
        cp -a "$M/etc/skel/." "$M/home/$UNAME/" 2>/dev/null || true
        chown -R "$UID_N:$UID_N" "$M/home/$UNAME"
        chmod 750 "$M/home/$UNAME"
        echo "  $UNAME: created uid=$UID_N, home seeded from /etc/skel"
    fi

    # --- supplementary groups (sudo is the one that matters) ---
    ADDED=""
    for g in sudo adm dialout cdrom audio video plugdev games users input netdev; do
        grep -q "^$g:" "$M/etc/group" || continue
        grep -E "^$g:[^:]*:[^:]*:.*\b$UNAME\b" "$M/etc/group" >/dev/null && continue
        sed -i "/^$g:/ s/:\([^:]*\)$/:\1,$UNAME/; /^$g:/ s/:,$UNAME$/:$UNAME/" "$M/etc/group"
        ADDED="$ADDED $g"
    done
    echo "  $UNAME groups:$ADDED"
    grep -E "^sudo:" "$M/etc/group" | sed 's/^/    /'

    # The first-login wizard only exists to collect what we just set.
    if [ -f "$M/root/.not_logged_in_yet" ]; then
        rm -f "$M/root/.not_logged_in_yet"
        echo "  removed .not_logged_in_yet (accounts already configured)"
    fi
fi

# ------------------------------------------------ ssh keys
sec "ssh keys"
if [ -z "$KEYS" ] && [ -f /mnt/c/opi/salvage/opi02w-4-config.tgz ]; then
    tar xzf /mnt/c/opi/salvage/opi02w-4-config.tgz -C /tmp home/swares/.ssh/authorized_keys 2>/dev/null \
        && KEYS=/tmp/home/swares/.ssh/authorized_keys && echo "  recovered from salvage tarball"
fi

if [ -n "$KEYS" ] && [ -f "$KEYS" ]; then
    # /root for immediate access; /etc/skel so the new user inherits them at creation.
    for d in "$M/root/.ssh" "$M/etc/skel/.ssh"; do
        mkdir -p "$d"; cp "$KEYS" "$d/authorized_keys"
        chmod 700 "$d"; chmod 600 "$d/authorized_keys"; chown -R 0:0 "$d"
    done

    # If the user's home was already created above, /etc/skel was copied before
    # the keys landed there - install them directly, owned by the user.
    if [ -d "$M/home/$UNAME" ]; then
        d="$M/home/$UNAME/.ssh"
        mkdir -p "$d"; cp "$KEYS" "$d/authorized_keys"
        chmod 700 "$d"; chmod 600 "$d/authorized_keys"
        chown -R "${UID_N:-1000}:${UID_N:-1000}" "$d"
        echo "  installed to /home/$UNAME/.ssh/ (uid ${UID_N:-1000})"
    fi
    awk '{print "  " $1, $NF}' "$KEYS"
else
    echo "  none supplied - password login only"
fi

# ------------------------------------------------ misc
sec "hostname + timezone"
echo "$HOSTNAME_NEW" > "$M/etc/hostname"
if grep -q '^127.0.1.1' "$M/etc/hosts"; then
    sed -i "s/^127.0.1.1.*/127.0.1.1\t$HOSTNAME_NEW/" "$M/etc/hosts"
else
    printf '127.0.1.1\t%s\n' "$HOSTNAME_NEW" >> "$M/etc/hosts"
fi
echo "  hostname: $HOSTNAME_NEW"

if [ -f "$M/usr/share/zoneinfo/$TZ" ]; then
    ln -sf "/usr/share/zoneinfo/$TZ" "$M/etc/localtime"
    echo "$TZ" > "$M/etc/timezone"
    echo "  timezone: $TZ"
fi

sec "verifying"
ls -la "$M/root/.not_logged_in_yet" "${FIRSTRUN_TPL%.template}" 2>/dev/null | sed 's/^/  /'
echo "  wifi target: $(grep -E '^FR_net_wifi_ssid' "${FIRSTRUN_TPL%.template}" 2>/dev/null)"
echo "  accounts with a usable password:"
awk -F: '$2 ~ /^\$6\$/ {print "    " $1}' "$M/etc/shadow"
echo "  sshd password auth: $(grep -hE '^\s*PasswordAuthentication' "$M/etc/ssh/sshd_config" "$M/etc/ssh/sshd_config.d/"*.conf 2>/dev/null | tr '\n' ' ')"
echo "  sshd root login   : $(grep -hE '^\s*PermitRootLogin' "$M/etc/ssh/sshd_config" "$M/etc/ssh/sshd_config.d/"*.conf 2>/dev/null | tr '\n' ' ')"
echo
echo "Image prepared. Unmounting."
cleanup; trap - EXIT
echo
echo "Next: flash $IMG to the card, then boot. Give it ~3 minutes for first-run"
echo "resize and wifi association, then look for '$HOSTNAME_NEW' in your router's"
echo "DHCP leases and: ssh $UNAME@$HOSTNAME_NEW"
