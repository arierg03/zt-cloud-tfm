$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Import-DotEnv {
    param([string]$EnvPath)

    if (-not (Test-Path $EnvPath)) {
        return
    }

    Get-Content $EnvPath | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            return
        }

        $eqIndex = $line.IndexOf("=")
        if ($eqIndex -lt 1) {
            return
        }

        $key = $line.Substring(0, $eqIndex).Trim()
        $value = $line.Substring($eqIndex + 1).Trim()

        if (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
    }
}

function Ensure-SvcTestDbUrl {
    if ($env:SVC_TEST_DATABASE_URL) {
        return
    }

    $pgUser = $env:POSTGRES_USER
    $pgPass = $env:POSTGRES_PASSWORD
    $pgDb = $env:POSTGRES_DB
    $pgHost = if ($env:POSTGRES_HOST) { $env:POSTGRES_HOST } else { "localhost" }
    $pgPort = if ($env:POSTGRES_PORT) { $env:POSTGRES_PORT } else { "5432" }

    if (-not $pgUser -or -not $pgPass -or -not $pgDb) {
        return
    }

    $env:SVC_TEST_DATABASE_URL = "postgresql://$pgUser`:$pgPass@$pgHost`:$pgPort/$pgDb"
}

Import-DotEnv -EnvPath ".env"
Ensure-SvcTestDbUrl

$apiPython = Join-Path $repoRoot "app\api\.venv\Scripts\python.exe"
$svcPython = Join-Path $repoRoot "app\svc\.venv\Scripts\python.exe"

if (-not (Test-Path $apiPython)) {
    Write-Host "[tests] ERROR: no existe $apiPython" -ForegroundColor Red
    Write-Host "[tests] Crea/activa el venv de API e instala requirements en app/api." -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $svcPython)) {
    Write-Host "[tests] ERROR: no existe $svcPython" -ForegroundColor Red
    Write-Host "[tests] Crea/activa el venv de SVC e instala requirements en app/svc." -ForegroundColor Yellow
    exit 1
}

if ($env:SVC_TEST_DATABASE_URL) {
    Write-Host "[tests] SVC_TEST_DATABASE_URL generada/cargada: $($env:SVC_TEST_DATABASE_URL)" -ForegroundColor DarkCyan
} else {
    Write-Host "[tests] Aviso: no se pudo construir SVC_TEST_DATABASE_URL (faltan POSTGRES_*)." -ForegroundColor Yellow
}

Write-Host "[tests] Ejecutando tests de API con app/api/.venv..." -ForegroundColor Cyan
& $apiPython -m pytest app/api/tests
$apiExit = $LASTEXITCODE

Write-Host "[tests] Ejecutando tests de SVC con app/svc/.venv..." -ForegroundColor Cyan
& $svcPython -m pytest app/svc/tests
$svcExit = $LASTEXITCODE

if ($apiExit -eq 0 -and $svcExit -eq 0) {
    Write-Host "[tests] OK: todas las suites pasaron." -ForegroundColor Green
    exit 0
}

Write-Host "[tests] ERROR: fallaron pruebas (api=$apiExit, svc=$svcExit)." -ForegroundColor Red
exit 1
