$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $projectRoot

$venvPython = Join-Path $projectRoot ".venv\Scripts\python.exe"
if (!(Test-Path -LiteralPath $venvPython)) {
    py -3 -m venv .venv
}

& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install -r requirements.txt
& $venvPython -m unittest discover -s tests -v
& $venvPython -m PyInstaller --noconfirm --clean SitePhotoReport.spec

$isccCandidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
)
$iscc = $isccCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($iscc) {
    & $iscc (Join-Path $projectRoot "installer.iss")
    Write-Output "Setup EXE: $(Join-Path $projectRoot 'installer-output\SitePhotoReport_Setup_0.8.1.exe')"
} else {
    Write-Warning "找不到 Inno Setup 6；已完成 dist\SitePhotoReport，可直接使用或自行安裝 Inno Setup 後再執行此腳本。"
}
