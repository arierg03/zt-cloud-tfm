param(
    [string]$Region = "eu-south-2",
    [string]$AccountId = "",
    [string]$RepositoryPrefix = "zt",
    [string]$Tag = "",
    [ValidateSet("api", "web", "svc")]
    [string[]]$Services = @("api", "web", "svc"),
    [string]$Platform = "linux/amd64",
    [string]$WebApiUrl = "/api",
    [switch]$NoCache,
    [switch]$SkipLatest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "No se encontro el comando '$Name'. Instalalo y vuelve a ejecutar."
    }
}

Require-Command -Name "aws"
Require-Command -Name "docker"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($Tag)) {
    $Tag = Get-Date -Format "yyyyMMdd-HHmmss"
}

if ([string]::IsNullOrWhiteSpace($AccountId)) {
    $AccountId = (aws sts get-caller-identity --query Account --output text).Trim()
}

if ([string]::IsNullOrWhiteSpace($AccountId) -or $AccountId -eq "None") {
    throw "No se pudo resolver AccountId. Pasa -AccountId o revisa tu AWS CLI profile."
}

$registry = "$AccountId.dkr.ecr.$Region.amazonaws.com"

Write-Host "Login en ECR: $registry"
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $registry | Out-Host

$definitions = @{
    api = @{
        Context = "app/api"
        Dockerfile = "app/api/Dockerfile"
        BuildArgs = @{}
    }
    web = @{
        Context = "app/web"
        Dockerfile = "app/web/Dockerfile"
        BuildArgs = @{ VITE_API_URL = $WebApiUrl }
    }
    svc = @{
        Context = "app/svc"
        Dockerfile = "app/svc/Dockerfile"
        BuildArgs = @{}
    }
}

$results = @()

foreach ($service in $Services) {
    if (-not $definitions.ContainsKey($service)) {
        throw "Servicio desconocido: $service"
    }

    $repoName = "$RepositoryPrefix/$service"
    $imageBase = "$registry/$repoName"
    $taggedImage = "$imageBase`:$Tag"
    $latestImage = "$imageBase`:latest"
    $def = $definitions[$service]

    Write-Host ""
    Write-Host "Comprobando repositorio ECR: $repoName"
    aws ecr describe-repositories --region $Region --repository-names $repoName | Out-Null

    $buildArgs = @(
        "buildx", "build",
        "--platform", $Platform,
        "--provenance=false",
        "--sbom=false",
        "--load",
        "-f", $def.Dockerfile,
        "-t", $taggedImage
    )
    if (-not $SkipLatest) {
        $buildArgs += @("-t", $latestImage)
    }
    if ($NoCache) {
        $buildArgs += "--no-cache"
    }

    foreach ($kv in $def.BuildArgs.GetEnumerator()) {
        $buildArgs += @("--build-arg", "$($kv.Key)=$($kv.Value)")
    }
    $buildArgs += $def.Context

    Write-Host "Building $service -> $taggedImage"
    & docker @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "El build de $service ha fallado."
    }

    Write-Host "Pushing $taggedImage"
    docker push $taggedImage | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "El push de $taggedImage ha fallado."
    }

    if (-not $SkipLatest) {
        Write-Host "Pushing $latestImage"
        docker push $latestImage | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "El push de $latestImage ha fallado."
        }
    }

    $results += [pscustomobject]@{
        service = $service
        tag = $Tag
        image = $taggedImage
        latest = if ($SkipLatest) { "(omitido)" } else { $latestImage }
    }
}

Write-Host ""
Write-Host "Imagenes actualizadas en ECR:"
$results | Format-Table -AutoSize | Out-Host
