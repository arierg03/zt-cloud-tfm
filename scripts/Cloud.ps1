param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("deploy", "stop", "status")]
    [string]$Action,

    [string]$Region = "eu-south-2",
    [string]$ClusterName = "tfm-app-eks",
    [ValidateSet("base", "zt")]
    [string]$EnvName = "base",
    [string]$EvidenceDir = "evaluation/results",
    [switch]$AdminBastion,
    [switch]$SkipKubernetes,
    [switch]$RemoteKubernetes,
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
        [bool]$CreateAdminBastion = $false,
        [string]$EksOidcIssuerUrl = ""
    )

    $repoRoot = Get-RepoRoot
    $tfvarsPath = Join-Path $repoRoot "infra\terraform\runtime.auto.tfvars"

    $lines = @(
        "create_eks = $($CreateEks.ToString().ToLower())",
        "create_rds = $($CreateRds.ToString().ToLower())",
        "create_nat = $($CreateNat.ToString().ToLower())",
        "create_admin_bastion = $($CreateAdminBastion.ToString().ToLower())"
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

function Get-TerraformOutputRaw {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $repoRoot = Get-RepoRoot
    $tfDir = Join-Path $repoRoot "infra\terraform"

    Push-Location $tfDir
    try {
        $value = & terraform output -raw $Name

        if ($LASTEXITCODE -ne 0) {
            throw "No se pudo obtener terraform output $Name"
        }

        return $value.Trim()
    }
    finally {
        Pop-Location
    }
}

function New-K8sManifestsPackage {
    $repoRoot = Get-RepoRoot
    $k8sDir = Join-Path $repoRoot "infra\k8s"

    if (-not (Test-Path $k8sDir)) {
        throw "No existe $k8sDir"
    }

    $packageDir = Join-Path ([System.IO.Path]::GetTempPath()) "tfm-k8s-artifacts"
    if (-not (Test-Path $packageDir)) {
        New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
    $packagePath = Join-Path $packageDir "k8s-manifests-$timestamp.zip"

    if (Test-Path $packagePath) {
        Remove-Item -Path $packagePath -Force
    }

    Compress-Archive -Path (Join-Path $k8sDir "*") -DestinationPath $packagePath -Force
    return $packagePath
}

function Publish-K8sManifestsPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,
        [Parameter(Mandatory = $true)]
        [string]$BucketName
    )

    $key = "manifests/$(Split-Path -Leaf $PackagePath)"
    $uploadOutput = aws s3 cp $PackagePath "s3://$BucketName/$key" --region $Region --only-show-errors 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo subir $PackagePath a s3://$BucketName/$key. $uploadOutput"
    }

    return $key
}

function Invoke-SsmShellCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId,
        [Parameter(Mandatory = $true)]
        [string[]]$Commands,
        [string]$Comment = "tfm remote kubernetes operation",
        [switch]$ShowOutput
    )

    $request = @{
        DocumentName = "AWS-RunShellScript"
        InstanceIds  = @($InstanceId)
        Comment      = $Comment
        Parameters   = @{
            commands = $Commands
        }
    }

    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = "utf-8"
    $requestPath = Join-Path ([System.IO.Path]::GetTempPath()) "tfm-ssm-command-$([guid]::NewGuid()).json"
    $requestJson = $request | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($requestPath, $requestJson, $utf8NoBom)

    try {
        $sendResult = aws ssm send-command --region $Region --cli-input-json "file://$requestPath" --output json | ConvertFrom-Json

        if ($LASTEXITCODE -ne 0) {
            throw "No se pudo enviar comando SSM al bastion $InstanceId"
        }

        $commandId = $sendResult.Command.CommandId
        Write-Host "SSM command id: $commandId"

        aws ssm wait command-executed --region $Region --command-id $commandId --instance-id $InstanceId
        $waitExitCode = $LASTEXITCODE

        $status = aws ssm get-command-invocation `
            --region $Region `
            --command-id $commandId `
            --instance-id $InstanceId `
            --query "Status" `
            --output text

        $responseCode = aws ssm get-command-invocation `
            --region $Region `
            --command-id $commandId `
            --instance-id $InstanceId `
            --query "ResponseCode" `
            --output text

        if ($ShowOutput -or $status -ne "Success" -or $responseCode -ne "0") {
            $stdout = aws ssm get-command-invocation `
                --region $Region `
                --command-id $commandId `
                --instance-id $InstanceId `
                --query "StandardOutputContent" `
                --output text 2>$null

            if ($LASTEXITCODE -eq 0 -and $stdout -and $stdout -ne "None") {
                Write-Host ($stdout -join [Environment]::NewLine)
            }

            $stderr = aws ssm get-command-invocation `
                --region $Region `
                --command-id $commandId `
                --instance-id $InstanceId `
                --query "StandardErrorContent" `
                --output text 2>$null

            if ($LASTEXITCODE -eq 0 -and $stderr -and $stderr -ne "None") {
                Write-Warning ($stderr -join [Environment]::NewLine)
            }
        }

        if ($waitExitCode -ne 0 -or $status -ne "Success" -or $responseCode -ne "0") {
            throw "El comando SSM fallo con estado $status y codigo $responseCode"
        }

        Write-Host "Comando SSM completado correctamente."
    }
    finally {
        if (Test-Path $requestPath) {
            Remove-Item -Path $requestPath -Force
        }

        if ($null -eq $previousPythonIoEncoding) {
            Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONIOENCODING = $previousPythonIoEncoding
        }
    }
}

function Wait-ForSsmManagedInstance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId,
        [int]$TimeoutSeconds = 300
    )

    $elapsed = 0

    while ($elapsed -lt $TimeoutSeconds) {
        $managedInstance = aws ssm describe-instance-information `
            --region $Region `
            --filters "Key=InstanceIds,Values=$InstanceId" `
            --query "InstanceInformationList[0].InstanceId" `
            --output text

        if ($LASTEXITCODE -eq 0 -and $managedInstance -eq $InstanceId) {
            Write-Host "Bastion registrado en SSM: $InstanceId"
            return
        }

        Write-Host "Esperando registro SSM del bastion... ${elapsed}s/${TimeoutSeconds}s"
        Start-Sleep -Seconds 15
        $elapsed += 15
    }

    throw "Timeout esperando a que el bastion $InstanceId se registre en SSM"
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

function Write-SkipKubernetesNotice {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("deploy", "stop", "status")]
        [string]$Action
    )

    Write-Warning "Modo SkipKubernetes activo: se omiten operaciones locales de kubeconfig, kubectl y helm."

    if ($Action -eq "deploy") {
        Write-Host "Aplica los manifiestos Kubernetes desde el bastion privado mediante SSM."
    }
    elseif ($Action -eq "stop") {
        Write-Host "Antes de destruir infraestructura, borra los recursos Kubernetes desde el bastion privado si el cluster sigue activo."
    }
}

function Write-RemoteKubernetesNotice {
    Write-Host "Modo RemoteKubernetes activo: las operaciones kubectl y helm se ejecutan en el bastion privado mediante SSM."
}

function Invoke-RemoteKubernetesDeploy {
    Write-Section "Publicar manifiestos Kubernetes en S3"
    $bucketName = Get-TerraformOutputRaw -Name "k8s_artifacts_bucket_name"
    $instanceId = Get-TerraformOutputRaw -Name "admin_bastion_instance_id"
    $packagePath = New-K8sManifestsPackage
    $s3Key = Publish-K8sManifestsPackage -PackagePath $packagePath -BucketName $bucketName

    Write-Host "Artefacto Kubernetes: s3://$bucketName/$s3Key"
    Write-Host "Bastion privado: $instanceId"
    Wait-ForSsmManagedInstance -InstanceId $instanceId

    $commands = @(
        'set -euo pipefail',
        'workdir=/tmp/tfm-k8s',
        'rm -rf "${workdir}"',
        'mkdir -p "${workdir}"/manifests',
        ('aws s3 cp "s3://{0}/{1}" "${{workdir}}"/k8s-manifests.zip --region {2}' -f $bucketName, $s3Key, $Region),
        'python3 -m zipfile -e "${workdir}"/k8s-manifests.zip "${workdir}"/manifests',
        'export KUBECONFIG="${workdir}"/kubeconfig',
        ('aws eks update-kubeconfig --region {0} --name {1} --kubeconfig "${{KUBECONFIG}}"' -f $Region, $ClusterName),
        'manifests="${workdir}"/manifests',
        'if [ -f "${manifests}"/aws-lbc-sa.yaml ]; then kubectl apply -f "${manifests}"/aws-lbc-sa.yaml; fi',
        'helm repo add eks https://aws.github.io/eks-charts || true',
        'helm repo update',
        ('helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName={0} --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller --set region={1} --set vpcId=vpc-036af3ec3778f5b1c >/tmp/tfm-helm-upgrade.out' -f $ClusterName, $Region),
        'kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=300s',
        'for file in namespace.yaml secret.local.yaml configmap.yaml serviceaccounts.yaml api.yaml svc.yaml web.yaml ingress.yaml networkpolicy.yaml; do if [ -f "${manifests}/${file}" ]; then kubectl apply -f "${manifests}/${file}"; else echo "No existe ${file}. Se omite."; fi; done',
        'for i in $(seq 1 40); do address=$(kubectl -n tfm-app get ingress tfm-app-ingress -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true); if [ -n "${address}" ]; then echo "Ingress disponible: http://${address}"; break; fi; echo "Esperando ADDRESS del Ingress... ${i}/40"; sleep 15; done',
        'kubectl -n tfm-app get pods,svc,ingress,networkpolicy'
    )

    Write-Section "Ejecutar Kubernetes remoto via SSM"
    Invoke-SsmShellCommand -InstanceId $instanceId -Commands $commands -Comment "tfm remote kubernetes deploy"
}

function Invoke-RemoteKubernetesStop {
    Write-Section "Borrar Kubernetes remoto via SSM"
    $instanceId = Get-TerraformOutputRaw -Name "admin_bastion_instance_id"
    Write-Host "Bastion privado: $instanceId"
    Wait-ForSsmManagedInstance -InstanceId $instanceId

    $commands = @(
        'set -euo pipefail',
        'workdir=/tmp/tfm-k8s-stop',
        'mkdir -p "${workdir}"',
        'export KUBECONFIG="${workdir}"/kubeconfig',
        ('aws eks update-kubeconfig --region {0} --name {1} --kubeconfig "${{KUBECONFIG}}"' -f $Region, $ClusterName),
        'kubectl -n tfm-app delete ingress tfm-app-ingress --ignore-not-found=true',
        'for i in $(seq 1 40); do if ! kubectl -n tfm-app get ingress tfm-app-ingress >/dev/null 2>&1; then echo "Ingress eliminado."; break; fi; echo "Esperando eliminacion del Ingress... ${i}/40"; sleep 15; done',
        'kubectl -n tfm-app delete networkpolicy --all --ignore-not-found=true',
        'kubectl -n tfm-app delete deployment api web --ignore-not-found=true',
        'kubectl -n tfm-app delete service api web svc --ignore-not-found=true',
        'kubectl -n tfm-app delete serviceaccount api svc --ignore-not-found=true',
        'kubectl -n tfm-app delete configmap --all --ignore-not-found=true',
        'kubectl -n tfm-app delete secret --all --ignore-not-found=true',
        'kubectl -n kube-system delete serviceaccount aws-load-balancer-controller --ignore-not-found=true'
    )

    Invoke-SsmShellCommand -InstanceId $instanceId -Commands $commands -Comment "tfm remote kubernetes stop"
}

function Invoke-RemoteKubernetesStatus {
    Write-Section "Kubernetes status remoto via SSM"
    $instanceId = Get-TerraformOutputRaw -Name "admin_bastion_instance_id"
    Write-Host "Bastion privado: $instanceId"
    Wait-ForSsmManagedInstance -InstanceId $instanceId

    $commands = @(
        'set -euo pipefail',
        'workdir=/tmp/tfm-k8s-status',
        'mkdir -p "${workdir}"',
        'export KUBECONFIG="${workdir}"/kubeconfig',
        ('aws eks update-kubeconfig --region {0} --name {1} --kubeconfig "${{KUBECONFIG}}"' -f $Region, $ClusterName),
        'kubectl get nodes',
        'kubectl -n tfm-app get pods,svc,ingress,networkpolicy',
        'kubectl -n kube-system get deployment aws-load-balancer-controller'
    )

    Invoke-SsmShellCommand -InstanceId $instanceId -Commands $commands -Comment "tfm remote kubernetes status" -ShowOutput
}

function Run-Deploy {
    Write-Section "Deploy cloud"

    Write-Section "Activar infraestructura base con coste"
    Write-RuntimeTfvars -CreateEks $true -CreateRds $true -CreateNat $true -CreateAdminBastion ($AdminBastion.IsPresent -or $RemoteKubernetes.IsPresent)

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

    if (-not $SkipKubernetes -and -not $RemoteKubernetes) {
        Write-Section "Actualizar kubeconfig"
        Update-Kubeconfig -Region $Region -ClusterName $ClusterName
    }
    elseif ($RemoteKubernetes) {
        Write-RemoteKubernetesNotice
    }
    else {
        Write-SkipKubernetesNotice -Action "deploy"
    }

    Write-Section "Detectar OIDC issuer del cluster"
    $oidcIssuer = Get-EksOidcIssuerUrl -Region $Region -ClusterName $ClusterName
    Write-Host "OIDC issuer: $oidcIssuer"

    Write-Section "Actualizar runtime.auto.tfvars con OIDC"
    Write-RuntimeTfvars -CreateEks $true -CreateRds $true -CreateNat $true -CreateAdminBastion ($AdminBastion.IsPresent -or $RemoteKubernetes.IsPresent) -EksOidcIssuerUrl $oidcIssuer

    Write-Section "Terraform apply IAM/OIDC"
    if ($AutoApprove) {
        Invoke-Terraform @("apply", "-auto-approve")
    }
    else {
        Invoke-Terraform @("apply")
    }

    if ($RemoteKubernetes) {
        Invoke-RemoteKubernetesDeploy
        return
    }

    if ($SkipKubernetes) {
        Write-Section "Kubernetes omitido"
        Write-Host "Infraestructura desplegada. Ejecuta la parte Kubernetes desde el bastion privado."
        return
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
        Write-Section "Detectar OIDC issuer actual"
        $oidcIssuer = Get-EksOidcIssuerUrl -Region $Region -ClusterName $ClusterName
        Write-Host "OIDC issuer: $oidcIssuer"

        if ($RemoteKubernetes) {
            Invoke-RemoteKubernetesStop
        }
        elseif ($SkipKubernetes) {
            Write-SkipKubernetesNotice -Action "stop"
        }
        else {
            Write-Section "Update kubeconfig"
            Update-Kubeconfig -Region $Region -ClusterName $ClusterName

            Write-Section "Delete Kubernetes resources"
            Invoke-KubectlDeleteForStop

            Write-Host ""
            Write-Host "Esperando 60 segundos para que AWS Load Balancer Controller elimine recursos externos..."
            Start-Sleep -Seconds 60
        }
    }
    else {
        Write-Warning "El cluster EKS $ClusterName no existe. Se omite borrado de manifiestos Kubernetes."
    }

    Write-RuntimeTfvars -CreateEks $false -CreateRds $false -CreateNat $false -CreateAdminBastion $false -EksOidcIssuerUrl $oidcIssuer

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

        if ($SkipKubernetes) {
            Write-SkipKubernetesNotice -Action "status"
        }
        elseif ($RemoteKubernetes) {
            Invoke-RemoteKubernetesStatus
        }
        else {
            try {
                Update-Kubeconfig -Region $Region -ClusterName $ClusterName
                kubectl -n tfm-app get pods,svc,ingress
            }
            catch {
                Write-Warning "No se pudo consultar Kubernetes: $($_.Exception.Message)"
            }
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

if ($SkipKubernetes -and $RemoteKubernetes) {
    throw "No se pueden usar -SkipKubernetes y -RemoteKubernetes a la vez."
}

switch ($Action) {
    "deploy" {
        if (-not $SkipKubernetes -and -not $RemoteKubernetes) {
            Require-Command -Name "kubectl"
            Require-Command -Name "helm"
        }
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
        if (-not $SkipKubernetes -and -not $RemoteKubernetes) {
            Require-Command -Name "kubectl"
        }
        Run-Stop
    }
    "status" {
        Run-Status
    }
}
