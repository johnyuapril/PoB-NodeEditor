# PoB Node Editor updater: downloads the latest editor files from GitHub and copies them over pob_calc.
$ErrorActionPreference = 'Stop'
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $root = $PSScriptRoot
  $cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'pob_calc\web\update.json') | ConvertFrom-Json
  $tmp = Join-Path $env:TEMP ('pobne_' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'u.zip'
  $url = "https://codeload.github.com/$($cfg.repo)/zip/refs/heads/$($cfg.branch)"
  Write-Output "download $url"
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
  if (-not (Test-Path (Join-Path $src.FullName 'pob_calc\driver.lua'))) { throw 'archive has no pob_calc\driver.lua' }
  robocopy (Join-Path $src.FullName 'pob_calc') (Join-Path $root 'pob_calc') /E /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy pob_calc failed ($LASTEXITCODE)" }
  if (Test-Path (Join-Path $src.FullName 'pob')) {
    robocopy (Join-Path $src.FullName 'pob') (Join-Path $root 'pob') /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy pob failed ($LASTEXITCODE)" }
  }
  foreach ($f in 'update.ps1', 'README.txt') {
    $s = Join-Path $src.FullName $f
    if (Test-Path $s) { Copy-Item -Path $s -Destination $root -Force }
  }
  Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Write-Output 'UPDATE_OK'
} catch {
  Write-Output ("UPDATE_FAIL " + $_.Exception.Message)
  exit 1
}
