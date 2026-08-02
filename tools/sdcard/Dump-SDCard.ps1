# Dump-SDCard.ps1
# Raw sector-for-sector dump of a physical disk to an image file, using direct
# \\.\PHYSICALDRIVEn access. Works on removable cards that Win32DiskImager,
# ImageUSB and `wsl --mount` refuse to enumerate.
#
# Computes a SHA256 of the data as it reads, so a later write-back can be verified.
#
# Usage (elevated PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\Dump-SDCard.ps1 -OutFile C:\opi\opi02w-4.img
#   powershell -ExecutionPolicy Bypass -File .\Dump-SDCard.ps1 -Drive 1 -OutFile C:\opi\card.img -ChunkMB 16
#
# READ ONLY with respect to the card. Never writes to the disk.

param(
    [int]$Drive = 1,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [int]$ChunkMB = 8
)

$devPath = "\\.\PHYSICALDRIVE$Drive"

# --- Determine disk size -------------------------------------------------
$disk = Get-CimInstance Win32_DiskDrive | Where-Object { $_.DeviceID -eq $devPath }
if (-not $disk) {
    Write-Host "No disk found at $devPath" -ForegroundColor Red
    Write-Host "Available:" -ForegroundColor Yellow
    Get-CimInstance Win32_DiskDrive | Select-Object DeviceID, Model, Size | Format-Table -AutoSize
    exit 1
}
$size = [int64]$disk.Size
$sizeGb = [math]::Round($size / 1GB, 2)
Write-Host "Source : $devPath  ($($disk.Model))  $sizeGb GB  [$size bytes]" -ForegroundColor Cyan

if ($size % 512 -ne 0) {
    Write-Host "Disk size is not a multiple of 512; refusing to guess." -ForegroundColor Red
    exit 1
}

# --- Check destination free space ---------------------------------------
$outDir = Split-Path -Parent $OutFile
if (-not $outDir) { $outDir = (Get-Location).Path }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$destRoot = [System.IO.Path]::GetPathRoot((Resolve-Path $outDir).Path)
$free = (Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $destRoot.TrimEnd('\') }).FreeSpace
if ($free -and $free -lt $size) {
    Write-Host ("Not enough free space on {0}: need {1:N2} GB, have {2:N2} GB" -f $destRoot, ($size/1GB), ($free/1GB)) -ForegroundColor Red
    exit 1
}
Write-Host "Target : $OutFile" -ForegroundColor Cyan
Write-Host ""

# --- Open handles --------------------------------------------------------
try {
    $src = [System.IO.File]::Open($devPath, [System.IO.FileMode]::Open,
                                  [System.IO.FileAccess]::Read,
                                  [System.IO.FileShare]::ReadWrite)
} catch {
    Write-Host "Cannot open $devPath : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Run as Administrator." -ForegroundColor Yellow
    exit 1
}

try {
    $dst = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create,
                                  [System.IO.FileAccess]::Write,
                                  [System.IO.FileShare]::None)
} catch {
    Write-Host "Cannot create $OutFile : $($_.Exception.Message)" -ForegroundColor Red
    $src.Close(); exit 1
}

$sha       = [System.Security.Cryptography.SHA256]::Create()
$chunk     = $ChunkMB * 1MB
$buf       = New-Object byte[] $chunk
$done      = [int64]0
$sw        = [System.Diagnostics.Stopwatch]::StartNew()
$lastPrint = 0
$badChunks = 0

try {
    while ($done -lt $size) {
        $want = [int][math]::Min([int64]$chunk, $size - $done)

        try {
            $read = $src.Read($buf, 0, $want)
        } catch {
            # A bad sector run: log it, write zeros to keep the image aligned, continue.
            Write-Host "`nRead error at offset $done - substituting zeros for $want bytes" -ForegroundColor Yellow
            [Array]::Clear($buf, 0, $want)
            $read = $want
            $badChunks++
            $src.Position = $done + $want
        }

        if ($read -le 0) {
            Write-Host "`nShort read at offset $done; stopping." -ForegroundColor Yellow
            break
        }

        $dst.Write($buf, 0, $read)
        [void]$sha.TransformBlock($buf, 0, $read, $null, 0)
        $done += $read

        if ($sw.Elapsed.TotalMilliseconds - $lastPrint -gt 500) {
            $lastPrint = $sw.Elapsed.TotalMilliseconds
            $pct   = [math]::Round(($done / $size) * 100, 1)
            $mbps  = if ($sw.Elapsed.TotalSeconds -gt 0) { ($done / 1MB) / $sw.Elapsed.TotalSeconds } else { 0 }
            $etaS  = if ($mbps -gt 0) { (($size - $done) / 1MB) / $mbps } else { 0 }
            $eta   = [TimeSpan]::FromSeconds([math]::Round($etaS))
            Write-Progress -Activity "Dumping $devPath" `
                -Status ("{0:N2} / {1:N2} GB   {2:N1} MB/s   ETA {3:hh\:mm\:ss}" -f ($done/1GB), ($size/1GB), $mbps, $eta) `
                -PercentComplete $pct
        }
    }
}
finally {
    $dst.Flush()
    $dst.Close()
    $src.Close()
    Write-Progress -Activity "Dumping $devPath" -Completed
}

[void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
$hash = ($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join ''
$sha.Dispose()
$sw.Stop()

Write-Host ""
Write-Host ("Copied  : {0:N2} GB in {1:hh\:mm\:ss} ({2:N1} MB/s avg)" -f ($done/1GB), $sw.Elapsed, (($done/1MB)/$sw.Elapsed.TotalSeconds)) -ForegroundColor Green
Write-Host "Image   : $OutFile"
Write-Host "SHA256  : $hash"
if ($badChunks -gt 0) {
    Write-Host "WARNING : $badChunks chunk(s) unreadable and zero-filled. The card may be failing." -ForegroundColor Yellow
}
$hash | Out-File -FilePath "$OutFile.sha256" -Encoding ASCII
Write-Host "Hash written to $OutFile.sha256" -ForegroundColor Cyan
