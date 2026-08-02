# Inspect-SDCard.ps1
# Read-only inspection of an SBC SD card's partition table and filesystem superblocks.
# Opens the raw disk, parses the MBR, and identifies each partition's filesystem
# plus the ext4 feature flags that determine Windows ext4 driver compatibility.
#
# Usage (elevated PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\Inspect-SDCard.ps1
#   powershell -ExecutionPolicy Bypass -File .\Inspect-SDCard.ps1 -Drive 2
#
# READ ONLY. Opens the handle with FileAccess::Read and never writes.

param([int]$Drive = 1)

$path = "\\.\PHYSICALDRIVE$Drive"
Write-Host "Opening $path (read-only)..." -ForegroundColor Cyan

try {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                                 [System.IO.FileAccess]::Read,
                                 [System.IO.FileShare]::ReadWrite)
} catch {
    Write-Host "Failed to open $path : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Are you running as Administrator?" -ForegroundColor Yellow
    exit 1
}

# Raw disk reads must be sector-aligned, so round outward and slice.
function Read-At([long]$offset, [int]$length) {
    $align = 512
    $start = [math]::Floor($offset / $align) * $align
    $delta = [int]($offset - $start)
    $total = [int]([math]::Ceiling(($delta + $length) / $align) * $align)
    $b = New-Object byte[] $total
    $script:fs.Position = $start
    [void]$script:fs.Read($b, 0, $total)
    return [byte[]]($b[$delta..($delta + $length - 1)])
}

$mbr = Read-At 0 512

if ($mbr[510] -ne 0x55 -or $mbr[511] -ne 0xAA) {
    Write-Host "No valid MBR signature found." -ForegroundColor Red
    $fs.Close(); exit 1
}

Write-Host ""
for ($i = 0; $i -lt 4; $i++) {
    $o    = 446 + $i * 16
    $type = $mbr[$o + 4]
    if ($type -eq 0) { continue }

    $lba = [BitConverter]::ToUInt32($mbr, $o + 8)
    $cnt = [BitConverter]::ToUInt32($mbr, $o + 12)
    $gb  = [math]::Round($cnt * 512 / 1GB, 2)

    if ($type -eq 0xEE) { Write-Host "GPT protective MBR - disk uses GPT, not MBR." -ForegroundColor Yellow }

    $typeName = switch ($type) {
        0x83 { "Linux" }; 0x82 { "Linux swap" }; 0x0B { "FAT32 CHS" }
        0x0C { "FAT32 LBA" }; 0x0E { "FAT16 LBA" }; 0x06 { "FAT16" }
        0x05 { "Extended" }; 0x07 { "NTFS/exFAT" }; default { "other" }
    }

    Write-Host ("Partition $($i+1): type=0x{0:X2} ({1})  startLBA={2}  {3} GB" -f $type, $typeName, $lba, $gb) -ForegroundColor White

    $base = [int64]$lba * 512

    # ext2/3/4 superblock lives 1024 bytes into the partition; s_magic at +0x38.
    $sb = Read-At ($base + 1024) 256
    $magic = [BitConverter]::ToUInt16($sb, 56)

    if ($magic -eq 0xEF53) {
        $compat   = [BitConverter]::ToUInt32($sb, 92)
        $incompat = [BitConverter]::ToUInt32($sb, 96)
        $roCompat = [BitConverter]::ToUInt32($sb, 100)
        $label    = ([Text.Encoding]::ASCII.GetString($sb, 120, 16)).Trim([char]0)
        $logBs    = [BitConverter]::ToUInt32($sb, 24)
        $blockSz  = 1024 -shl $logBs
        $blocks   = [BitConverter]::ToUInt32($sb, 4)
        $sizeGb   = [math]::Round(([double]$blocks * $blockSz) / 1GB, 2)

        $hasExtents = ($incompat -band 0x0040) -ne 0
        $has64bit   = ($incompat -band 0x0080) -ne 0
        $hasCsum    = ($roCompat -band 0x0400) -ne 0
        $hasJournal = ($compat   -band 0x0004) -ne 0

        $fsName = if ($hasExtents) { "ext4" } elseif ($hasJournal) { "ext3" } else { "ext2" }

        Write-Host "   Filesystem : $fsName   label='$label'   fs size=$sizeGb GB   block=$blockSz" -ForegroundColor Green
        Write-Host ("   incompat=0x{0:X}  ro_compat=0x{1:X}  compat=0x{2:X}" -f $incompat, $roCompat, $compat)
        Write-Host "   extents=$hasExtents  64bit=$has64bit  metadata_csum=$hasCsum  journal=$hasJournal"

        if (-not $hasExtents) {
            Write-Host "   -> No extents. DiskInternals Linux Writer will refuse this volume." -ForegroundColor Yellow
        } elseif ($has64bit) {
            Write-Host "   -> 64bit feature set. This is the usual cause of Linux Writer rejecting an ext4 volume." -ForegroundColor Yellow
        } else {
            Write-Host "   -> Should be writable by Linux Writer." -ForegroundColor Green
        }
    }
    else {
        # Not ext*. Probe the other filesystems common on SBC images.
        $btr = [Text.Encoding]::ASCII.GetString((Read-At ($base + 65600) 8))
        $f2  = [BitConverter]::ToUInt32((Read-At ($base + 1024) 4), 0)
        $fat = ([Text.Encoding]::ASCII.GetString((Read-At ($base + 82) 8))).Trim()
        $fat2= ([Text.Encoding]::ASCII.GetString((Read-At ($base + 54) 8))).Trim()

        if     ($btr -eq '_BHRfS_M')   { Write-Host "   Filesystem : btrfs" -ForegroundColor Green }
        elseif ($f2  -eq 0xF2F52010)   { Write-Host "   Filesystem : f2fs"  -ForegroundColor Green }
        elseif ($fat -like 'FAT*')     { Write-Host "   Filesystem : $fat (FAT32)" -ForegroundColor Green }
        elseif ($fat2 -like 'FAT*')    { Write-Host "   Filesystem : $fat2" -ForegroundColor Green }
        else { Write-Host ("   Filesystem : unrecognized (ext magic read as 0x{0:X4})" -f $magic) -ForegroundColor Yellow }
    }
    Write-Host ""
}

$fs.Close()
Write-Host "Done. Nothing was written to the card." -ForegroundColor Cyan
