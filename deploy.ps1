<#
.SYNOPSIS
    Windows deployment of cockpit-guac-rdp. There is not one, and this script
    says why rather than producing an install that cannot work.

.DESCRIPTION
    cockpit-guac-rdp is a Cockpit plugin whose entire back end is Linux host
    machinery: a guacd CONTAINER under podman, a relay daemon authenticated by
    SO_PEERCRED over an AF_UNIX socket, systemd socket activation, an nftables
    owner-match that decides which uid may reach guacd, a polkit rule, a D-Bus
    policy drop-in, and gnome-remote-desktop. Every one of those is a Linux
    kernel or systemd facility with no Windows counterpart - SO_PEERCRED and the
    nftables uid gate are the security model, not implementation details.

    So there is nothing to copy into C:\Program Files that would function. A
    deploy.ps1 that copied files anyway would leave a host that looks installed
    and is not, which is worse than one that is plainly not installed.

    See docs/DEPLOY-CONTRACT.md section 1.2: Windows is out of scope for the six
    Cockpit plugins. The Windows half of that contract exists for the components
    that genuinely ship there.

.NOTES
    Windows is a CLIENT of this plugin, and a first-class one: point a browser
    at https://<linux-host>:9090 and use the Remote Desktop page, or connect
    mstsc.exe to the 3390 "Remote Login" door once it is configured.
#>
[CmdletBinding()]
param()

Write-Host ''
Write-Host 'cockpit-guac-rdp does not deploy to Windows.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  Its back end is podman, systemd socket activation, SO_PEERCRED'
Write-Host '  peer authentication, an nftables uid gate, polkit and D-Bus. Those'
Write-Host '  are the security model, and none of them exists here.'
Write-Host ''
Write-Host '  Deploy on the Linux host:'
Write-Host '      sudo ./deploy.sh --all           # deps, users, image, units'
Write-Host ''
Write-Host '  Then use it FROM Windows, which is fully supported:'
Write-Host '      https://<that-host>:9090  ->  Remote Desktop'
Write-Host '      or mstsc.exe to the 3390 door (docs/KNOWN_ISSUES.md, I29)'
Write-Host ''
exit 1
