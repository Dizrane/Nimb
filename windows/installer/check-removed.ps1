# check-removed.ps1: shows whether Nimb left anything behind.
#   check-removed.ps1 snapshot <file>   write what is on this computer that Nimb could touch
#   check-removed.ps1 compare <before> <after>   list every difference (an empty list is a clean removal)
# Run it as an administrator, once before the installation and once after the removal.
param([string]$mode, [string]$a, [string]$b)
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Snapshot {
    $lines = New-Object System.Collections.Generic.List[string]
    # services
    Get-Service | Where-Object { $_.Name -match 'Nimb' } | ForEach-Object { $lines.Add("service: $($_.Name) $($_.Status)") }
    # folders and files of Nimb
    $dirs = @("$env:ProgramFiles\Nimb", "$env:ProgramData\Nimb", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Nimb.lnk")
    Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $dirs += "$($_.FullName)\AppData\Roaming\Nimb"
        $dirs += "$($_.FullName)\AppData\Roaming\Nimb.exe"
        $dirs += "$($_.FullName)\AppData\Local\Nimb"
    }
    foreach ($d in $dirs) {
        if (Test-Path $d) {
            Get-ChildItem $d -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $lines.Add("file: $($_.FullName)") }
            $lines.Add("file: $d")
        }
    }
    # registry of the machine and of the loaded users
    foreach ($k in 'HKLM:\SOFTWARE\Nimb', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Nimb') {
        if (Test-Path $k) { $lines.Add("registry: $k") }
    }
    New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
    Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -notmatch '_Classes$' } | ForEach-Object {
        $run = "$($_.PSPath)\Software\Microsoft\Windows\CurrentVersion\Run"
        if ((Get-ItemProperty $run -ErrorAction SilentlyContinue).Nimb) { $lines.Add("autostart: $($_.PSChildName)") }
    }
    # the adapter and the DNS of the adapters
    Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Nimb' -or $_.InterfaceDescription -match 'Wintun|WireGuard Tunnel' } | ForEach-Object { $lines.Add("adapter: $($_.Name) $($_.InterfaceDescription)") }
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue | ForEach-Object {
        $v = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).NameServer
        if ($v) { $lines.Add("static dns: $($_.PSChildName) = $v") }
    }
    # the driver of the adapter
    (pnputil /enum-drivers 2>$null) | Select-String -Pattern 'Wintun' | ForEach-Object { $lines.Add("driver: $($_.Line.Trim())") }
    $lines | Sort-Object
}

switch ($mode) {
    'snapshot' {
        $found = @(Snapshot)
        [IO.File]::WriteAllLines($a, [string[]]$found)    # an empty file is a fine answer: nothing is there
        "snapshot: $($found.Count) lines -> $a"
    }
    'compare' {
        $before = @(Get-Content $a -ErrorAction SilentlyContinue); $after = @(Get-Content $b -ErrorAction SilentlyContinue)
        $diff = Compare-Object -ReferenceObject $before -DifferenceObject $after
        if (-not $diff) { 'CLEAN: nothing left, nothing missing'; exit 0 }
        $diff | ForEach-Object { '{0} {1}' -f $(if ($_.SideIndicator -eq '=>') { 'LEFT BEHIND:' } else { 'GONE:' }), $_.InputObject }
        exit 1
    }
    default { 'usage: check-removed.ps1 snapshot <file> | compare <before> <after>' }
}
