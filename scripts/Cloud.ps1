param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("deploy", "stop", "status")]
    [string]$Action,

    [string]$Region = "eu-south-2",
    [string]$ClusterName = "tfm-app-eks",
    [ValidateSet("base", "zt")]
    [string]$EnvName = "base",
    [string]$EvidenceDir = "evaluation/results",
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

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Object | ConvertTo-Json -Depth 30 | Out-File -FilePath $Path -Encoding utf8
}

function Write-DeploymentEvidence {
    param(
        [Parameter(Mandatory = $true)][datetime]$StartUtc,
        [Parameter(Mandatory = $true)][datetime]$EndUtc
    )

    $repoRoot = Get-RepoRoot
    $resolvedDir = Join-Path (Join-Path $repoRoot $EvidenceDir) $EnvName

    if (-not (Test-Path $resolvedDir)) {
        New-Item -ItemType Directory -Path $resolvedDir -Force | Out-Null
    }

    $seconds = [int][math]::Round(($EndUtc - $StartUtc).TotalSeconds, 0)
    $evidence = @{
        action = "deploy"
        environment = $EnvName
        region = $Region
        cluster_name = $ClusterName
        started_at_utc = $StartUtc.ToString("o")
        finished_at_utc = $EndUtc.ToString("o")
        deployment_seconds = $seconds
        deployment_minutes = [math]::Round($seconds / 60, 2)
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $outputPath = Join-Path $resolvedDir "deployment_time_$EnvName.json"
    Write-JsonFile -Object $evidence -Path $outputPath
    Write-Host "Evidencia de tiempo de despliegue: $outputPath"
}

function Write-RuntimeTfvars {
    param(
        [bool]$CreateEks,
        [bool]$CreateRds,
        [bool]$CreateNat,
        [string]$EksOidcIssuerUrl = ""
    )

    $repoRoot = Get-RepoRoot
    $tfvarsPath = Join-Path $repoRoot "infra\terraform\runtime.auto.tfvars"

    $lines = @(
        "create_eks = $($CreateEks.ToString().ToLower())",
        "create_rds = $($CreateRds.ToString().ToLower())",
        "create_nat = $($CreateNat.ToString().ToLower())"
    )

    if ($EksOidcIssuerUrl -eq "" -and (Test-Path $tfvarsPath)) {
        $existing = Get-Content $tfvarsPath | Where-Object { $_ -match '^eks_oidc_issuer_url\s*=' } | Select-Object -First 1
        if ($existing) {
            $EksOidcIssuerUrl = ($existing -replace 'eks_oidc_issuer_url\s*=\s*"', '') -replace '"', ''
        }
    }

    if ($EksOidcIssuerUrl -ne "") {
        $lines += "eks_oidc_issuer_url = `"$EksOidcIssuerUrl`""
    }

    Set-Content -Path $tfvarsPath -Value ($lines -join "`n") -Encoding UTF8
    Write-Host "Escrito $tfvarsPath"
}

function Get-EksOidcIssuerUrl {
    param(
        [string]$Region,
        [string]$ClusterName
    )

    $issuer = aws eks describe-cluster `
        --region $Region `
        --name $ClusterName `
        --query "cluster.identity.oidc.issuer" `
        --output text

    if (-not $issuer -or $issuer -eq "None") {
        throw "No se pudo obtener el issuer OIDC del cluster $ClusterName"
    }

    return $issuer.Trim()
}

function Invoke-Terraform {
    param(
        [string[]]$Arguments
    )

    $repoRoot = Get-RepoRoot
    $tfDir = Join-Path $repoRoot "infra\terraform"

    Push-Location $tfDir
    try {
        & terraform @Arguments

        if ($LASTEXITCODE -ne 0) {
            throw "Terraform fallo con codigo de salida $LASTEXITCODE"
        }
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
        "serviceaccounts.yaml",
        "api.yaml",
        "svc.yaml",
        "web.yaml",
        "ingress.yaml",
        "networkpolicy.yaml"
    )

    foreach ($file in $files) {
        $path = Join-Path $k8sDir $file
        if (Test-Path $path) {
            kubectl apply -f $path

            if ($LASTEXITCODE -ne 0) {
                throw "kubectl apply fallo para $path"
            }
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
        "networkpolicy.yaml",
        "web.yaml",
        "api.yaml",
        "svc.yaml",
        "serviceaccounts.yaml",
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

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo actualizar kubeconfig para el cluster $ClusterName"
    }
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

function Repair-PrivateNatRoutes {
    param(
        [string]$Region
    )

    $routeTables = @(
        "rtb-027d0f5547df67cd5",
        "rtb-0bbd08a1834142062"
    )

    foreach ($rtb in $routeTables) {
        $route = aws ec2 describe-route-tables `
            --region $Region `
            --route-table-ids $rtb `
            --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'] | [0]" `
            --output json | ConvertFrom-Json

        if ($route -and $route.State -eq "blackhole") {
            Write-Warning "Eliminando ruta blackhole 0.0.0.0/0 en $rtb"
            aws ec2 delete-route `
                --region $Region `
                --route-table-id $rtb `
                --destination-cidr-block 0.0.0.0/0
        }
    }
}

function Install-LoadBalancerController {
    param(
        [string]$Region,
        [string]$ClusterName
    )

    Require-Command -Name "helm"

    helm repo add eks https://aws.github.io/eks-charts | Out-Host
    helm repo update | Out-Host

    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller `
        -n kube-system `
        --set clusterName=$ClusterName `
        --set serviceAccount.create=false `
        --set serviceAccount.name=aws-load-balancer-controller `
        --set region=$Region `
        --set vpcId=vpc-036af3ec3778f5b1c

    if ($LASTEXITCODE -ne 0) {
        throw "Fallo instalando AWS Load Balancer Controller"
    }
}

function Wait-ForIngressAddress {
    param(
        [string]$Namespace = "tfm-app",
        [string]$IngressName = "tfm-app-ingress",
        [int]$TimeoutSeconds = 600
    )

    $elapsed = 0

    while ($elapsed -lt $TimeoutSeconds) {
        $address = ""
        try {
            $address = kubectl -n $Namespace get ingress $IngressName -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>$null
        }
        catch {
            $address = ""
        }

        if ($address) {
            Write-Host "Ingress disponible: http://$address"
            return
        }

        Write-Host "Esperando ADDRESS del Ingress... ${elapsed}s/${TimeoutSeconds}s"
        Start-Sleep -Seconds 15
        $elapsed += 15
    }

    throw "Timeout esperando ADDRESS del Ingress $IngressName"
}

function Invoke-KubectlApplyFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $repoRoot = Get-RepoRoot
    $k8sDir = Join-Path $repoRoot "infra\k8s"
    $path = Join-Path $k8sDir $FileName

    if (-not (Test-Path $path)) {
        throw "No existe $path"
    }

    kubectl apply -f $path

    if ($LASTEXITCODE -ne 0) {
        throw "kubectl apply fallo para $path"
    }
}

function Wait-ForLoadBalancerController {
    param(
        [int]$TimeoutSeconds = 300
    )

    Write-Host "Esperando a que AWS Load Balancer Controller este listo..."

    kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout="${TimeoutSeconds}s"

    if ($LASTEXITCODE -ne 0) {
        throw "AWS Load Balancer Controller no quedo listo dentro del timeout"
    }
}

function Run-Deploy {
    Write-Section "Deploy cloud"

    Write-Section "Activar infraestructura base con coste"
    Write-RuntimeTfvars -CreateEks $true -CreateRds $true -CreateNat $true

    Write-Section "Terraform init"
    Invoke-Terraform @("init")

    Write-Section "Terraform validate"
    Invoke-Terraform @("validate")

    Write-Section "Reparar rutas NAT blackhole previas"
    Repair-PrivateNatRoutes -Region $Region

    Write-Section "Terraform apply infraestructura"
    if ($AutoApprove) {
        Invoke-Terraform @("apply", "-auto-approve")
    }
    else {
        Invoke-Terraform @("apply")
    }

    Write-Section "Actualizar kubeconfig"
    Update-Kubeconfig -Region $Region -ClusterName $ClusterName

    Write-Section "Detectar OIDC issuer del cluster"
    $oidcIssuer = Get-EksOidcIssuerUrl -Region $Region -ClusterName $ClusterName
    Write-Host "OIDC issuer: $oidcIssuer"

    Write-Section "Actualizar runtime.auto.tfvars con OIDC"
    Write-RuntimeTfvars -CreateEks $true -CreateRds $true -CreateNat $true -EksOidcIssuerUrl $oidcIssuer

    Write-Section "Terraform apply IAM/OIDC"
    if ($AutoApprove) {
        Invoke-Terraform @("apply", "-auto-approve")
    }
    else {
        Invoke-Terraform @("apply")
    }

    Write-Section "Aplicar ServiceAccount del Load Balancer Controller"
    Invoke-KubectlApplyFile -FileName "aws-lbc-sa.yaml"

    Write-Section "Instalar AWS Load Balancer Controller"
    Install-LoadBalancerController -Region $Region -ClusterName $ClusterName

    Write-Section "Esperar AWS Load Balancer Controller"
    Wait-ForLoadBalancerController

    Write-Section "Aplicar manifiestos Kubernetes"
    Invoke-KubectlApply

    Write-Section "Esperar Ingress ALB"
    Wait-ForIngressAddress

    Write-Section "Kubernetes status"
    kubectl -n tfm-app get pods,svc,ingress,networkpolicy
}

function Run-Stop {
    Write-Section "Stop cloud"

    $oidcIssuer = ""

    if (Test-EksClusterExists -Region $Region -ClusterName $ClusterName) {
        Write-Section "Update kubeconfig"
        Update-Kubeconfig -Region $Region -ClusterName $ClusterName

        Write-Section "Detectar OIDC issuer actual"
        $oidcIssuer = Get-EksOidcIssuerUrl -Region $Region -ClusterName $ClusterName
        Write-Host "OIDC issuer: $oidcIssuer"

        Write-Section "Delete Kubernetes resources"
        Invoke-KubectlDeleteForStop

        Write-Host ""
        Write-Host "Esperando 60 segundos para que AWS Load Balancer Controller elimine recursos externos..."
        Start-Sleep -Seconds 60
    }
    else {
        Write-Warning "El cluster EKS $ClusterName no existe. Se omite borrado de manifiestos Kubernetes."
    }

    Write-RuntimeTfvars -CreateEks $false -CreateRds $false -CreateNat $false -EksOidcIssuerUrl $oidcIssuer

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
        Require-Command -Name "helm"
        $deployStartUtc = (Get-Date).ToUniversalTime()
        try {
            Run-Deploy
        }
        finally {
            $deployEndUtc = (Get-Date).ToUniversalTime()
            Write-DeploymentEvidence -StartUtc $deployStartUtc -EndUtc $deployEndUtc
        }
    }
    "stop" {
        Require-Command -Name "kubectl"
        Run-Stop
    }
    "status" {
        Run-Status
    }
}
