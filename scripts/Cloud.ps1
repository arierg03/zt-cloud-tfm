param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("deploy", "stop", "status")]
    [string]$Action,

    [string]$Region = "eu-south-2",
    [string]$ClusterName = "tfm-app-eks",
    [switch]$AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "No se encontro el comando '$Name'. Instalalo y vuelve a ejecutar."
    }
}

function Get-RepoRoot {
    $dir = $PSScriptRoot

    while ($dir -and -not (Test-Path (Join-Path $dir "infra\terraform"))) {
        $parent = Split-Path -Parent $dir

        if ($parent -eq $dir) {
            throw "No se pudo encontrar la raiz del repositorio. Se esperaba encontrar infra\terraform."
        }

        $dir = $parent
    }

    return $dir
}

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "==== $Text ===="
}

function Write-RuntimeTfvars {
    param(
        [bool]$CreateEks,
        [bool]$CreateRds,
        [bool]$CreateNat
    )

    $repoRoot = Get-RepoRoot
    $tfvarsPath = Join-Path $repoRoot "infra\terraform\runtime.auto.tfvars"

    $content = @"
create_eks = $($CreateEks.ToString().ToLower())
create_rds = $($CreateRds.ToString().ToLower())
create_nat = $($CreateNat.ToString().ToLower())
"@

    Set-Content -Path $tfvarsPath -Value $content -Encoding UTF8
    Write-Host "Escrito $tfvarsPath"
}

function Invoke-Terraform {
    param(
        [string[]]$Arguments
    )

    $repoRoot = Get-RepoRoot
    $tfDir = Join-Path $repoRoot "infra\terraform"

    Push-Location $tfDir
    try {
        terraform @Arguments
    }
    finally {
        Pop-Location
    }
}

function Invoke-KubectlApply {
    $repoRoot = Get-RepoRoot
    $k8sDir = Join-Path $repoRoot "infra\k8s"

    $files = @(
        "namespace.yaml",
        "secret.local.yaml",
        "configmap.yaml",
        "aws-lbc-sa.yaml",
        "api.yaml",
        "svc.yaml",
        "web.yaml",
        "ingress.yaml"
    )

    foreach ($file in $files) {
        $path = Join-Path $k8sDir $file
        if (Test-Path $path) {
            kubectl apply -f $path
        }
        else {
            Write-Warning "No existe $path. Se omite."
        }
    }
}

function Invoke-KubectlDeleteForStop {
    $repoRoot = Get-RepoRoot
    $k8sDir = Join-Path $repoRoot "infra\k8s"

    $files = @(
        "ingress.yaml",
        "web.yaml",
        "api.yaml",
        "svc.yaml",
        "configmap.yaml",
        "aws-lbc-sa.yaml",
        "secret.local.yaml"
    )

    foreach ($file in $files) {
        $path = Join-Path $k8sDir $file
        if (Test-Path $path) {
            kubectl delete -f $path --ignore-not-found=true
        }
        else {
            Write-Warning "No existe $path. Se omite."
        }
    }
}

function Update-Kubeconfig {
    param(
        [string]$Region,
        [string]$ClusterName
    )

    aws eks update-kubeconfig --region $Region --name $ClusterName
}

function Test-EksClusterExists {
    param(
        [string]$Region,
        [string]$ClusterName
    )

    try {
        aws eks describe-cluster --region $Region --name $ClusterName *> $null
        return $true
    }
    catch {
        return $false
    }
}

function Show-RdsStatus {
    param(
        [string]$Region
    )

    $instances = aws rds describe-db-instances `
        --region $Region `
        --query "DBInstances[?DBInstanceIdentifier=='tfm-app-rds'].{id:DBInstanceIdentifier,status:DBInstanceStatus,class:DBInstanceClass,engine:Engine}" `
        --output json | ConvertFrom-Json

    if (-not $instances -or $instances.Count -eq 0) {
        Write-Host "Instancia RDS no existe."
        return
    }

    $instances | Format-Table -AutoSize
}

function Show-NatStatus {
    param(
        [string]$Region
    )

    $natGateways = aws ec2 describe-nat-gateways `
        --region $Region `
        --filter "Name=vpc-id,Values=vpc-036af3ec3778f5b1c" `
        --query "NatGateways[?State!='deleted'].{id:NatGatewayId,state:State,subnet:SubnetId}" `
        --output json | ConvertFrom-Json

    if (-not $natGateways -or $natGateways.Count -eq 0) {
        Write-Host "No hay NAT Gateways activas en la VPC."
        return
    }

    $natGateways | Format-Table -AutoSize
}

function Run-Deploy {
    Write-Section "Deploy cloud"

    Write-RuntimeTfvars -CreateEks $true -CreateRds $true -CreateNat $true

    Write-Section "Terraform init"
    Invoke-Terraform @("init")

    Write-Section "Terraform validate"
    Invoke-Terraform @("validate")

    Write-Section "Terraform apply"
    if ($AutoApprove) {
        Invoke-Terraform @("apply", "-auto-approve")
    }
    else {
        Invoke-Terraform @("apply")
    }

    Write-Section "Update kubeconfig"
    Update-Kubeconfig -Region $Region -ClusterName $ClusterName

    Write-Section "Apply Kubernetes manifests"
    Invoke-KubectlApply

    Write-Section "Kubernetes status"
    kubectl -n tfm-app get pods,svc,ingress
}

function Run-Stop {
    Write-Section "Stop cloud"

    if (Test-EksClusterExists -Region $Region -ClusterName $ClusterName) {
        Write-Section "Update kubeconfig"
        Update-Kubeconfig -Region $Region -ClusterName $ClusterName

        Write-Section "Delete Kubernetes resources"
        Invoke-KubectlDeleteForStop

        Write-Host ""
        Write-Host "Esperando 60 segundos para que AWS Load Balancer Controller elimine recursos externos..."
        Start-Sleep -Seconds 60
    }
    else {
        Write-Warning "El cluster EKS $ClusterName no existe. Se omite borrado de manifiestos Kubernetes."
    }

    Write-RuntimeTfvars -CreateEks $false -CreateRds $false -CreateNat $false

    Write-Section "Terraform apply"
    if ($AutoApprove) {
        Invoke-Terraform @("apply", "-auto-approve")
    }
    else {
        Invoke-Terraform @("apply")
    }
}

function Run-Status {
    Write-Section "Terraform state"
    Invoke-Terraform @("state", "list")

    Write-Section "Terraform plan"
    Invoke-Terraform @("plan")

    Write-Section "EKS"
    if (Test-EksClusterExists -Region $Region -ClusterName $ClusterName) {
        aws eks describe-cluster --region $Region --name $ClusterName --query "cluster.{name:name,status:status,version:version}" --output table

        try {
            Update-Kubeconfig -Region $Region -ClusterName $ClusterName
            kubectl -n tfm-app get pods,svc,ingress
        }
        catch {
            Write-Warning "No se pudo consultar Kubernetes: $($_.Exception.Message)"
        }
    }
    else {
        Write-Host "Cluster EKS no existe."
    }

    Write-Section "RDS"
    Show-RdsStatus -Region $Region

    Write-Section "NAT Gateways"
    Show-NatStatus -Region $Region
}

Require-Command -Name "aws"
Require-Command -Name "terraform"

switch ($Action) {
    "deploy" {
        Require-Command -Name "kubectl"
        Run-Deploy
    }
    "stop" {
        Require-Command -Name "kubectl"
        Run-Stop
    }
    "status" {
        Run-Status
    }
}