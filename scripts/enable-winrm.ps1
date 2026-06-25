# enable-winrm.ps1
# Run ONCE on each n150 as Administrator before Ansible can manage it.
# Opens WinRM over HTTP on port 5985 with NTLM auth (LAN-only; fine for a trusted network).
#
# Usage (from an elevated PowerShell prompt on the target):
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\enable-winrm.ps1

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "==> Enabling WinRM service..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck

Write-Host "==> Setting WinRM service to auto-start..."
Set-Service -Name WinRM -StartupType Automatic

Write-Host "==> Ensuring Negotiate (NTLM/Kerberos) auth is enabled..."
# Negotiate covers NTLM — no separate NTLM path exists in WSMan.
# Enable-PSRemoting already enables Negotiate; this is belt-and-suspenders.
Set-Item -Path WSMan:\localhost\Service\Auth\Negotiate -Value $true

Write-Host "==> Opening firewall for WinRM (port 5985, LAN subnet only)..."
$rule = Get-NetFirewallRule -DisplayName "WinRM-Lab" -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule `
        -DisplayName  "WinRM-Lab" `
        -Direction    Inbound `
        -Protocol     TCP `
        -LocalPort    5985 `
        -RemoteAddress 192.168.1.0/24 `
        -Action       Allow `
        -Profile      Any
}

Write-Host "==> WinRM listener status:"
winrm enumerate winrm/config/listener

Write-Host ""
Write-Host "Done. Test from H4 with:"
Write-Host "  ansible -i ansible/inventory/hosts.yml n150-1 -m win_ping"
