# Write-SDCard.ps1
# Writes a raw disk image to a physical drive via direct \\.\PHYSICALDRIVEn access.
# For removable cards that Etcher, Rufus and Win32DiskImager refuse to enumerate.
#
# Usage (elevated PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\Write-SDCard.ps1 `
#       -Image C:\opi\Orangepizero2w_1.0.2_debian_bookworm_server_linux6.1.31.img -Drive 1
#
# Safety: refuses PHYSICALDRIVE0, refuses fixed disks, refuses any disk larger
# than -MaxSizeGB, and requires you to type the disk's model string to proceed.
# Verifies by reading back what it wrote and comparing SHA256.

param(
    [Parameter(Mandatory = $true)][string]$Image,
    [int]$Drive = 1,
    [int]$ChunkMB = 8,
    [int]$MaxSizeGB = 256,
    [switch]$NoVerify
)

$ErrorActionPreference = 'Stop'
$devPath = "\\.\PHYSICALDRIVE$Drive"

function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $Image)) { Fail "image not found: $Image" }
$imgSize = (Get-Item $Image).Length
if ($imgSize % 512 -ne 0) { Fail "image size $imgSize is not a multiple of 512" }

# ---------------------------------------------------------------- safety
if ($Drive -eq 0) { Fail "refusing to write to PHYSICALDRIVE0 (system disk)" }

$disk = Get-CimInstance Win32_DiskDrive | Where-Object { $_.DeviceID -eq $devPath }
if (-not $disk) {
    Write-Host "No disk at $devPath. Available:" -ForegroundColor Yellow
    Get-CimInstance Win32_DiskDrive | Select-Object DeviceID, Model, MediaType, Size | Format-Table -AutoSize
    exit 1
}

$diskSize = [int64]$disk.Size
if ($disk.MediaType -notlike '*Removable*') {
    Fail "$devPath is '$($disk.MediaType)', not removable. Refusing."
}
if ($diskSize -gt ($MaxSizeGB * 1GB)) {
    Fail "$devPath is $([math]::Round($diskSize/1GB,1)) GB, over the $MaxSizeGB GB guard. Refusing."
}
if ($imgSize -gt $diskSize) {
    Fail "image ($([math]::Round($imgSize/1GB,2)) GB) is larger than the card ($([math]::Round($diskSize/1GB,2)) GB)"
}

Write-Host ""
Write-Host "  Image  : $Image" -ForegroundColor Cyan
Write-Host "           $([math]::Round($imgSize/1GB,2)) GB"
Write-Host "  Target : $devPath" -ForegroundColor Yellow
Write-Host "           $($disk.Model)  |  $($disk.MediaType)  |  $([math]::Round($diskSize/1GB,2)) GB"
Write-Host ""
Write-Host "  EVERYTHING ON THIS DISK WILL BE DESTROYED." -ForegroundColor Red
Write-Host ""

$expect = $disk.Model.Trim()
$typed = Read-Host "  Type the model exactly to confirm ('$expect')"
if ($typed.Trim() -ne $expect) { Fail "confirmation did not match. Nothing written." }

# ------------------------------------------- lock and dismount the volumes
# Windows blocks raw writes to sector ranges owned by a mounted filesystem,
# which surfaces as "Access to the path is denied". Set-Disk -IsOffline does
# not work on removable media ("Removable media cannot be set to offline"), so
# instead lock and dismount each volume directly and hold the handles open for
# the duration of the write - the same thing Win32DiskImager does.

if (-not ('W32.Vol' -as [type])) {
    Add-Type -Namespace 'W32' -Name 'Vol' -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess,
    uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
    uint dwFlagsAndAttributes, IntPtr hTemplateFile);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
    IntPtr lpInBuffer, uint nInBufferSize, IntPtr lpOutBuffer, uint nOutBufferSize,
    ref uint lpBytesReturned, IntPtr lpOverlapped);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(IntPtr hObject);
'@
}

$FSCTL_LOCK_VOLUME     = 0x00090018
$FSCTL_DISMOUNT_VOLUME = 0x00090020
$volHandles = @()

$letters = @()
try {
    $letters = Get-Partition -DiskNumber $Drive -ErrorAction Stop |
               Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter }
} catch { }

if ($letters.Count -gt 0) {
    Write-Host "  mounted volumes on disk ${Drive}: $($letters -join ', ')" -ForegroundColor DarkGray
    foreach ($l in $letters) {
        $h = [W32.Vol]::CreateFile("\\.\${l}:", 0xC0000000, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        if ($h.ToInt64() -eq -1) {
            Write-Host "  WARNING: could not open volume ${l}:" -ForegroundColor Yellow
            continue
        }
        $br = [uint32]0
        $lock = [W32.Vol]::DeviceIoControl($h, $FSCTL_LOCK_VOLUME,     [IntPtr]::Zero,0,[IntPtr]::Zero,0,[ref]$br,[IntPtr]::Zero)
        $dis  = [W32.Vol]::DeviceIoControl($h, $FSCTL_DISMOUNT_VOLUME, [IntPtr]::Zero,0,[IntPtr]::Zero,0,[ref]$br,[IntPtr]::Zero)
        Write-Host ("  {0}: locked={1} dismounted={2}" -f $l, $lock, $dis) -ForegroundColor DarkGray
        if (-not $lock) {
            Write-Host "  ${l}: lock refused - close any Explorer window or app using this drive" -ForegroundColor Yellow
        }
        $volHandles += $h
    }
    Start-Sleep -Milliseconds 500
} else {
    Write-Host "  no mounted volumes on disk $Drive (nothing to dismount)" -ForegroundColor DarkGray
}

try {
    $sd = Get-Disk -Number $Drive -ErrorAction Stop
    if ($sd.IsReadOnly) { Set-Disk -Number $Drive -IsReadOnly $false; Write-Host "  cleared read-only flag" }
} catch { }

# ---------------------------------------------------------------- write
$src = [System.IO.File]::Open($Image, 'Open', 'Read', 'Read')
try {
    $dst = [System.IO.File]::Open($devPath, [System.IO.FileMode]::Open,
                                  [System.IO.FileAccess]::Write,
                                  [System.IO.FileShare]::ReadWrite)
} catch {
    $src.Close()
    foreach ($h in $volHandles) { [void][W32.Vol]::CloseHandle($h) }
    Fail @"
cannot open $devPath for writing: $($_.Exception.Message)
  Run as Administrator, and close any Explorer window on the card.
  If it still fails, wipe the partition table so nothing can mount it:
    diskpart -> list disk -> select disk $Drive -> clean -> exit
  (dismiss any 'You need to format the disk' popup - do NOT format)
"@
}

$sha   = [System.Security.Cryptography.SHA256]::Create()
$chunk = $ChunkMB * 1MB
$buf   = New-Object byte[] $chunk
$done  = [int64]0
$sw    = [System.Diagnostics.Stopwatch]::StartNew()
$last  = 0

Write-Host ""
try {
    while ($done -lt $imgSize) {
        $want = [int][math]::Min([int64]$chunk, $imgSize - $done)
        $read = $src.Read($buf, 0, $want)
        if ($read -le 0) { break }

        $dst.Write($buf, 0, $read)
        [void]$sha.TransformBlock($buf, 0, $read, $null, 0)
        $done += $read

        if ($sw.Elapsed.TotalMilliseconds - $last -gt 500) {
            $last = $sw.Elapsed.TotalMilliseconds
            $mbps = ($done / 1MB) / [math]::Max($sw.Elapsed.TotalSeconds, 0.001)
            $eta  = [TimeSpan]::FromSeconds([math]::Round((($imgSize - $done)/1MB) / [math]::Max($mbps,0.001)))
            Write-Progress -Activity "Writing to $devPath" `
                -Status ("{0:N2} / {1:N2} GB   {2:N1} MB/s   ETA {3:hh\:mm\:ss}" -f ($done/1GB), ($imgSize/1GB), $mbps, $eta) `
                -PercentComplete (($done / $imgSize) * 100)
        }
    }
    $dst.Flush($true)
}
finally {
    $dst.Close(); $src.Close()
    # Release the volume locks now that the write is done.
    foreach ($h in $volHandles) { [void][W32.Vol]::CloseHandle($h) }
    $volHandles = @()
    Write-Progress -Activity "Writing to $devPath" -Completed
}

[void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
$srcHash = ($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join ''
$sha.Dispose(); $sw.Stop()

Write-Host ("  Wrote  : {0:N2} GB in {1:hh\:mm\:ss} ({2:N1} MB/s)" -f ($done/1GB), $sw.Elapsed, (($done/1MB)/$sw.Elapsed.TotalSeconds)) -ForegroundColor Green
Write-Host "  SHA256 : $srcHash"

# ---------------------------------------------------------------- verify
if (-not $NoVerify) {
    Write-Host ""
    Write-Host "  Verifying (reading back $([math]::Round($done/1GB,2)) GB)..." -ForegroundColor Cyan
    $vs   = [System.IO.File]::Open($devPath, 'Open', 'Read', 'ReadWrite')
    $vsha = [System.Security.Cryptography.SHA256]::Create()
    $vd   = [int64]0
    $sw2  = [System.Diagnostics.Stopwatch]::StartNew(); $last = 0
    try {
        while ($vd -lt $done) {
            $want = [int][math]::Min([int64]$chunk, $done - $vd)
            $r = $vs.Read($buf, 0, $want)
            if ($r -le 0) { break }
            [void]$vsha.TransformBlock($buf, 0, $r, $null, 0)
            $vd += $r
            if ($sw2.Elapsed.TotalMilliseconds - $last -gt 500) {
                $last = $sw2.Elapsed.TotalMilliseconds
                Write-Progress -Activity "Verifying" -PercentComplete (($vd / $done) * 100) `
                    -Status ("{0:N2} / {1:N2} GB" -f ($vd/1GB), ($done/1GB))
            }
        }
    } finally { $vs.Close(); Write-Progress -Activity "Verifying" -Completed }

    [void]$vsha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
    $dstHash = ($vsha.Hash | ForEach-Object { $_.ToString('x2') }) -join ''
    $vsha.Dispose()

    Write-Host "  Read   : $dstHash"
    if ($dstHash -eq $srcHash) {
        Write-Host "  VERIFIED - card matches image" -ForegroundColor Green
    } else {
        Write-Host "  MISMATCH - the write did not land correctly. Do not boot this card." -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------- finish
Write-Host ""
Write-Host "  Eject the card and put it in the board." -ForegroundColor Cyan
Write-Host "  Windows will not recognise the ext4 filesystem - that is expected."
Write-Host "  Ignore any 'You need to format the disk' prompt. Do NOT format."
Write-Host ""
Write-Host "  On boot: ~3 min for filesystem resize and wifi association," -ForegroundColor Cyan
Write-Host "  then look for 'opi02w-4' in your router's DHCP leases."
