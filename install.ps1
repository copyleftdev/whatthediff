# wtd installer for Windows PowerShell — downloads the matching release
# binary, verifies its SHA256, installs it, and puts it on your user PATH.
#
#   irm https://raw.githubusercontent.com/copyleftdev/whatthediff/main/install.ps1 | iex
#
# Environment overrides: WTD_VERSION (default: latest), WTD_INSTALL_DIR
$ErrorActionPreference = "Stop"
$repo = "copyleftdev/whatthediff"

$version = if ($env:WTD_VERSION) { $env:WTD_VERSION } else {
    (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
}
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64" } else { "x86_64" }
$name = "wtd-$version-$arch-windows"
$base = "https://github.com/$repo/releases/download/$version"

$tmp = Join-Path $env:TEMP "wtd-install-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Write-Host "wtd-install: downloading $name.zip ($version)"
    $zip = Join-Path $tmp "$name.zip"
    Invoke-WebRequest "$base/$name.zip" -OutFile $zip

    $sums = (Invoke-WebRequest "$base/SHA256SUMS").Content
    $line = ($sums -split "`n" | Where-Object { $_ -match [regex]::Escape("$name.zip") } | Select-Object -First 1)
    if (-not $line) { throw "no checksum entry for $name.zip" }
    $expected = ($line -split '\s+')[0].ToLower()
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { throw "checksum verification FAILED" }
    Write-Host "wtd-install: checksum verified"

    Expand-Archive $zip -DestinationPath $tmp

    $dest = if ($env:WTD_INSTALL_DIR) { $env:WTD_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "Programs\wtd" }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $tmp "$name\wtd.exe") (Join-Path $dest "wtd.exe") -Force
    Write-Host "wtd-install: installed -> $dest\wtd.exe"

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$dest*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$dest", "User")
        Write-Host "wtd-install: added $dest to your user PATH (restart your shell)"
    }
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
