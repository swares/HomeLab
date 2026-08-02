#!/bin/bash
# diag-opi.sh - offline diagnosis of the mounted opi02w-4 rootfs
# Run as root in WSL with the image mounted at /mnt/opi:
#   bash diag-opi.sh > /tmp/opi-diag.txt 2>&1 ; cat /tmp/opi-diag.txt

R=/mnt/opi

if [ ! -f "$R/etc/os-release" ]; then
    echo "ERROR: nothing mounted at $R"
    exit 1
fi

sec() { echo; echo "===================== $* ====================="; }

sec "PASSWORD STATE"
# Field 2: '!' or '*' = locked/no password. '$6$...' = SHA-512 hash present.
for u in root swares; do
    line=$(grep "^$u:" "$R/etc/shadow")
    if [ -z "$line" ]; then
        echo "$u: NO SHADOW ENTRY"
    else
        hash=$(echo "$line" | cut -d: -f2)
        case "$hash" in
            '!'|'!!'|'*'|'') state="LOCKED / no password" ;;
            \$6\$*)          state="SHA-512 hash present" ;;
            \$y\$*)          state="yescrypt hash present" ;;
            *)               state="hash type: ${hash:0:3}" ;;
        esac
        echo "$u: $state   (lastchg day $(echo "$line" | cut -d: -f3))"
    fi
done

sec "ENABLED UNITS - multi-user.target.wants"
ls "$R/etc/systemd/system/multi-user.target.wants/" 2>&1

sec "ENABLED UNITS - network / ssh related, anywhere"
find "$R/etc/systemd/system" -maxdepth 3 \
     \( -iname '*network*' -o -iname '*ssh*' -o -iname '*wpa*' -o -iname '*iwd*' -o -iname '*dhcp*' \) \
     -printf '%p -> %l\n' 2>&1

sec "UNIT FILES AVAILABLE (are NM and sshd even installed?)"
ls "$R/usr/lib/systemd/system/" 2>/dev/null | grep -iE '^(NetworkManager|sshd|wpa_supplicant|systemd-networkd|iwd)'

sec "MASKED UNITS"
find "$R/etc/systemd/system" -maxdepth 2 -lname '/dev/null' -printf '%f MASKED\n' 2>&1

sec "SSHD CONFIG DROP-INS"
ls -la "$R/etc/ssh/sshd_config.d/" 2>&1
cat "$R/etc/ssh/sshd_config.d/"*.conf 2>/dev/null

sec "AUTHORIZED KEYS (type + comment only, no key material)"
awk '{print $1, $NF}' "$R/home/swares/.ssh/authorized_keys" 2>&1

sec "WIRELESS MODULES BUILT"
find "$R/lib/modules" -path '*net/wireless*' -name '*.ko*' -printf '%f\n' 2>/dev/null | sort | head -40
echo "--- vendor blobs for Allwinner-class wifi ---"
find "$R/lib/modules" "$R/lib/firmware" \
     \( -iname '*8800*' -o -iname '*xr82*' -o -iname '*uwe*' -o -iname '*sprd*' -o -iname '*aw859*' \) 2>/dev/null | head -20

sec "MODULE LOAD CONFIG"
cat "$R/etc/modules-load.d/"*.conf 2>/dev/null
cat "$R/etc/modprobe.d/"*.conf 2>/dev/null | grep -viE '^\s*#' | head -20

# ---------------- journal ----------------
JD=$(ls -d "$R"/var/log/journal/*/ 2>/dev/null | head -1)

if [ -z "$JD" ]; then
    echo; echo "No persistent journal directory found."
else
    sec "JOURNAL LOCATION"
    echo "$JD"
    du -sh "$JD"

    sec "JOURNAL - BOOT LIST"
    journalctl -D "$JD" --list-boots --no-pager 2>&1 | tail -20

    sec "JOURNAL - KERNEL WIFI/FIRMWARE (last boot)"
    journalctl -D "$JD" -k -b -1 --no-pager 2>&1 \
      | grep -iE 'wlan|wifi|firmware|brcmf|aic|xr82|sunxi-mmc|mmc1|sdio' | tail -50

    sec "JOURNAL - NETWORKMANAGER / WPA (last boot)"
    journalctl -D "$JD" -b -1 --no-pager 2>&1 \
      | grep -iE 'NetworkManager|wpa_suppl|supplicant|Linksys|associat|auth' | tail -50

    sec "JOURNAL - ERRORS (last boot)"
    journalctl -D "$JD" -b -1 -p err --no-pager 2>&1 | tail -40

    sec "JOURNAL - LAST 40 LINES BEFORE SHUTDOWN"
    journalctl -D "$JD" -b -1 --no-pager 2>&1 | tail -40
fi

sec "DONE"
