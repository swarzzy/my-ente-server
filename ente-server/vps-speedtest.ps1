# vps-speedtest.ps1 - measure download and upload speed between this PC and the Ente server over HTTPS.
# On the server first:  sudo ./ente-setup.sh speedtest   (prints the URL; it works for 30 minutes)
# Usage:  .\vps-speedtest.ps1 -Url https://api.<domain>/speedtest-<token>   [-SizeMB 50]
# If scripts are blocked:  powershell -ExecutionPolicy Bypass -File .\vps-speedtest.ps1 -Url ...
# Needs curl.exe (part of Windows 10 and later).
param(
  [Parameter(Mandatory = $true)][string]$Url,
  [int]$SizeMB = 50
)
$ErrorActionPreference = "Stop"
$Url = $Url.TrimEnd("/")
$inv = [Globalization.CultureInfo]::InvariantCulture
function Show([string]$what, [string]$r) {
  # $r = "<bytes per second> <seconds> <http code>" from curl -w
  $p = $r.Trim() -split " "
  if ($p.Count -lt 3 -or $p[2] -ne "200") { Write-Host "${what}: FAILED (HTTP $($p[-1])): wrong or expired URL, or the server is unreachable"; return }
  $bps = [double]::Parse($p[0], $inv); $sec = [double]::Parse($p[1], $inv)
  Write-Host ("{0}: {1:N1} s = {2:N1} MB/s ({3:N0} Mbit/s)" -f $what, $sec, ($bps / 1MB), ($bps * 8 / 1000000))
}

Write-Host "server $Url, $SizeMB MB each way"
$r = curl.exe -s -o NUL -m 20 -w "%{time_connect} %{time_starttransfer} %{http_code}" "$Url/down/1"
Write-Host "latency:  connect / first byte / HTTP code: $r"

Write-Host "downloading..."
$r = curl.exe -# -o NUL -m 900 -w "%{speed_download} %{time_total} %{http_code}" "$Url/down/$SizeMB"
Show "download" $r

$up = Join-Path $env:TEMP ("vps-speed-" + [guid]::NewGuid().ToString("N") + ".bin")
try {
  $buf = New-Object byte[] (1MB); $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $fs = [IO.File]::OpenWrite($up)
  for ($i = 0; $i -lt $SizeMB; $i++) { $rng.GetBytes($buf); $fs.Write($buf, 0, $buf.Length) }
  $fs.Close()
  Write-Host "uploading..."
  $r = curl.exe -# -o NUL -m 900 -T $up -w "%{speed_upload} %{time_total} %{http_code}" "$Url/up"
  Show "upload  " $r
}
finally { Remove-Item -Force $up -ErrorAction SilentlyContinue }
