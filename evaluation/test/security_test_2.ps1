param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("base", "zt")]
    [string]$EnvName,

    [string]$Region = "eu-south-2",

    [string]$ClusterName = "tfm-app-eks",

    [string]$Namespace = "default",

    [string]$OutputDir = "evidences",

    [switch]$SkipKubectl,

    [string]$ProbeImage = "nicolaka/netshoot:latest",

    [string]$ApiServiceHost = "api",

    [int]$ApiServicePort = 8000,

    [string]$RdsHost = "",

    [int]$RdsPort = 5432,

    [string]$S3Bucket = "",

    [string]$S3Region = "eu-south-2",

    [string]$S3TestObjectKey = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "No se encontró el comando '$Name'. Instálalo o añádelo al PATH."
    }
}

function ConvertTo-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $json = $Object | ConvertTo-Json -Depth 20
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $json, $utf8Bom)
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $raw = & aws @Arguments --output json 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        return $null
    }

    return $raw | ConvertFrom-Json
}

function Invoke-KubectlJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $raw = & kubectl @Arguments -o json 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        return $null
    }

    return $raw | ConvertFrom-Json
}

function Invoke-KubectlText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $raw = & kubectl @Arguments 2>&1
    return @{
        code = $LASTEXITCODE
        output = (($raw | Out-String).Trim())
    }
}

function Get-InternalAccessEvidence {
    Write-Host "[S4] Recogiendo evidencia de acceso interno (movimiento lateral)..." -ForegroundColor Cyan

    if ($SkipKubectl) {
        return @{
            status = "SKIPPED"
            message = "Comprobación S4 omitida mediante -SkipKubectl."
            checks = @()
        }
    }

    $probePodName = "s4-probe-$EnvName-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $checks = @()

    try {
        $createProbe = Invoke-KubectlText -Arguments @(
            "run", $probePodName,
            "-n", $Namespace,
            "--image", $ProbeImage,
            "--restart=Never",
            "--command", "--", "sh", "-c", "sleep 900"
        )

        if ($createProbe.code -ne 0) {
            return @{
                status = "ERROR"
                message = "No se pudo crear el pod de prueba S4."
                create_output = $createProbe.output
                checks = @()
            }
        }

        $waitProbe = Invoke-KubectlText -Arguments @(
            "wait", "pod/$probePodName",
            "-n", $Namespace,
            "--for=condition=Ready",
            "--timeout=120s"
        )

        if ($waitProbe.code -ne 0) {
            return @{
                status = "ERROR"
                message = "El pod de prueba S4 no llegó a estado Ready."
                wait_output = $waitProbe.output
                checks = @()
            }
        }

        $apiHealthCmd = "curl -s -o /dev/null -w '%{http_code}' http://$ApiServiceHost`:$ApiServicePort/health"
        $apiHealth = Invoke-KubectlText -Arguments @(
            "exec", "-n", $Namespace, $probePodName, "--", "sh", "-lc", $apiHealthCmd
        )
        $apiHealthCode = $apiHealth.output

        $checks += @{
            component = "api-internal-health"
            target = "http://$ApiServiceHost`:$ApiServicePort/health"
            reachable = ($apiHealth.code -eq 0 -and $apiHealthCode -eq "200")
            classification = if ($apiHealth.code -eq 0 -and $apiHealthCode -eq "200") { "FAIL_MODERATE" } else { "PASS" }
            reason = if ($apiHealth.code -eq 0 -and $apiHealthCode -eq "200") {
                "Pod interno con acceso directo al health del servicio API."
            } else {
                "No se alcanzó el endpoint interno health."
            }
            raw = $apiHealth.output
        }

        $apiDocsCmd = "curl -s -o /dev/null -w '%{http_code}' http://$ApiServiceHost`:$ApiServicePort/docs"
        $apiDocs = Invoke-KubectlText -Arguments @(
            "exec", "-n", $Namespace, $probePodName, "--", "sh", "-lc", $apiDocsCmd
        )
        $apiDocsCode = $apiDocs.output

        $checks += @{
            component = "api-internal-docs"
            target = "http://$ApiServiceHost`:$ApiServicePort/docs"
            reachable = ($apiDocs.code -eq 0 -and $apiDocsCode -eq "200")
            classification = if ($apiDocs.code -eq 0 -and $apiDocsCode -eq "200") { "FAIL_CRITICAL" } else { "PASS" }
            reason = if ($apiDocs.code -eq 0 -and $apiDocsCode -eq "200") {
                "Pod interno puede acceder directamente a documentación interna de API."
            } else {
                "No se alcanzó /docs interno."
            }
            raw = $apiDocs.output
        }

        if ($RdsHost) {
            $rdsCmd = "nc -zvw3 $RdsHost $RdsPort >/dev/null 2>&1 && echo OPEN || echo CLOSED"
            $rdsCheck = Invoke-KubectlText -Arguments @(
            "exec", "-n", $Namespace, $probePodName, "--", "sh", "-lc", $rdsCmd
            )

            $rdsOpen = ($rdsCheck.output -match "OPEN")

            $checks += @{
            component = "rds-internal-tcp"
            target = "$RdsHost`:$RdsPort"
            reachable = $rdsOpen
            classification = if ($rdsOpen) { "FAIL_CRITICAL" } else { "PASS" }
            reason = if ($rdsOpen) {
                "Pod interno puede abrir conexión TCP directa con RDS."
            } else {
                "RDS no accesible por TCP desde el pod de prueba."
            }
            raw = $rdsCheck.output
            }
        } else {
            $checks += @{
                component = "rds-internal-tcp"
                target = $null
                reachable = $false
                classification = "SKIPPED"
                reason = "Comprobación omitida (sin -RdsHost)."
                raw = ""
            }
        }

        if ($S3Bucket) {
            $bucketUrl = "https://$S3Bucket.s3.$S3Region.amazonaws.com"
            $s3BucketCmd = "curl -s -o /dev/null -w '%{http_code}' $bucketUrl"
            $s3BucketCheck = Invoke-KubectlText -Arguments @(
                "exec", "-n", $Namespace, $probePodName, "--", "sh", "-lc", $s3BucketCmd
            )
            $s3BucketCode = $s3BucketCheck.output

            $checks += @{
                component = "s3-internal-anon-bucket"
                target = $bucketUrl
                reachable = ($s3BucketCheck.code -eq 0)
                classification = if ($s3BucketCheck.code -eq 0 -and $s3BucketCode -eq "200") { "FAIL_CRITICAL" } elseif ($s3BucketCode -in @("403", "404")) { "PASS" } else { "FAIL_MODERATE" }
                reason = if ($s3BucketCheck.code -eq 0 -and $s3BucketCode -eq "200") {
                    "Bucket S3 accesible de forma anónima desde pod interno."
                } elseif ($s3BucketCode -in @("403", "404")) {
                    "Bucket no accesible anónimamente."
                } else {
                    "Respuesta inesperada al comprobar bucket S3."
                }
                raw = $s3BucketCheck.output
            }

            if ($S3TestObjectKey) {
                $normalizedKey = $S3TestObjectKey.TrimStart("/")
                $objectUrl = "$bucketUrl/$normalizedKey"
                $s3ObjCmd = "curl -s -o /dev/null -w '%{http_code}' $objectUrl"
                $s3ObjCheck = Invoke-KubectlText -Arguments @(
                    "exec", "-n", $Namespace, $probePodName, "--", "sh", "-lc", $s3ObjCmd
                )
                $s3ObjCode = $s3ObjCheck.output

                $checks += @{
                    component = "s3-internal-anon-object"
                    target = $objectUrl
                    reachable = ($s3ObjCheck.code -eq 0)
                    classification = if ($s3ObjCheck.code -eq 0 -and $s3ObjCode -eq "200") { "FAIL_CRITICAL" } elseif ($s3ObjCode -in @("403", "404")) { "PASS" } else { "FAIL_MODERATE" }
                    reason = if ($s3ObjCheck.code -eq 0 -and $s3ObjCode -eq "200") {
                        "Objeto S3 accesible de forma anónima desde pod interno."
                    } elseif ($s3ObjCode -in @("403", "404")) {
                        "Objeto no accesible anónimamente."
                    } else {
                        "Respuesta inesperada al comprobar objeto S3."
                    }
                    raw = $s3ObjCheck.output
                }
            }
        } else {
            $checks += @{
                component = "s3-internal-anon-bucket"
                target = $null
                reachable = $false
                classification = "SKIPPED"
                reason = "Comprobación omitida (sin -S3Bucket)."
                raw = ""
            }
        }
    }
    finally {
        $null = Invoke-KubectlText -Arguments @(
            "delete", "pod", $probePodName,
            "-n", $Namespace,
            "--ignore-not-found=true",
            "--wait=false"
        )
    }

    $critical = @($checks | Where-Object { $_.classification -eq "FAIL_CRITICAL" })
    $moderate = @($checks | Where-Object { $_.classification -eq "FAIL_MODERATE" })

    return @{
        status = "OK"
        description = "Evidencia para S4. Simula acceso interno desde un pod para evaluar exposición lateral a API interna, RDS y S3."
        probe_pod_image = $ProbeImage
        probe_namespace = $Namespace
        checks_count = $checks.Count
        critical_count = $critical.Count
        moderate_count = $moderate.Count
        checks = $checks
    }
}

function Get-IamRolesEvidence {
    Write-Host "[S5] Recogiendo evidencias IAM..." -ForegroundColor Cyan

    $roles = Invoke-AwsJson -Arguments @("iam", "list-roles")

    if (-not $roles) {
        return @{
            status = "ERROR"
            message = "No se pudieron listar roles IAM."
            roles_count = $null
            potentially_relevant_roles = @()
        }
    }

    $patterns = @(
        "tfm",
        "eks",
        "ecr",
        "rds",
        "s3",
        "alb",
        "loadbalancer",
        "node",
        "cluster"
    )

    $relevantRoles = @()

    foreach ($role in $roles.Roles) {
        $roleNameLower = $role.RoleName.ToLower()
        $isRelevant = $false

        foreach ($pattern in $patterns) {
            if ($roleNameLower.Contains($pattern)) {
                $isRelevant = $true
                break
            }
        }

        if (-not $isRelevant) {
            continue
        }

        $attachedPolicies = Invoke-AwsJson -Arguments @(
            "iam", "list-attached-role-policies",
            "--role-name", $role.RoleName
        )

        $inlinePolicies = Invoke-AwsJson -Arguments @(
            "iam", "list-role-policies",
            "--role-name", $role.RoleName
        )

        $attachedPolicyNames = @()
        $attachedPolicyArns = @()

        if ($attachedPolicies -and $attachedPolicies.AttachedPolicies) {
            $attachedPolicyNames = @($attachedPolicies.AttachedPolicies | ForEach-Object { $_.PolicyName })
            $attachedPolicyArns = @($attachedPolicies.AttachedPolicies | ForEach-Object { $_.PolicyArn })
        }

        $inlinePolicyNames = @()

        if ($inlinePolicies -and $inlinePolicies.PolicyNames) {
            $inlinePolicyNames = @($inlinePolicies.PolicyNames)
        }

        $adminLikePolicies = @(
            $attachedPolicyNames | Where-Object {
                $_ -match "AdministratorAccess|PowerUserAccess|FullAccess"
            }
        )

        $relevantRoles += @{
            role_name = $role.RoleName
            arn = $role.Arn
            created_at = $role.CreateDate
            attached_policy_count = $attachedPolicyNames.Count
            attached_policy_names = $attachedPolicyNames
            attached_policy_arns = $attachedPolicyArns
            inline_policy_count = $inlinePolicyNames.Count
            inline_policy_names = $inlinePolicyNames
            admin_like_policy_names = $adminLikePolicies
        }
    }

    $rolesWithAdminLikePolicies = @(
        $relevantRoles | Where-Object {
            $_.admin_like_policy_names.Count -gt 0
        }
    )

    return @{
        status = "OK"
        description = "Evidencia para S5. Permite comparar número de roles, políticas asociadas y presencia de políticas amplias."
        roles_count_total = $roles.Roles.Count
        potentially_relevant_roles_count = $relevantRoles.Count
        roles_with_admin_like_policies_count = $rolesWithAdminLikePolicies.Count
        potentially_relevant_roles = $relevantRoles
    }
}

function Get-EksClusterEvidence {
    Write-Host "[S6] Recogiendo evidencias del clúster EKS..." -ForegroundColor Cyan

    $cluster = Invoke-AwsJson -Arguments @(
        "eks", "describe-cluster",
        "--region", $Region,
        "--name", $ClusterName
    )

    if (-not $cluster) {
        return @{
            status = "ERROR"
            message = "No se pudo describir el clúster EKS '$ClusterName'."
        }
    }

    $clusterInfo = $cluster.cluster

    return @{
        status = "OK"
        cluster_name = $clusterInfo.name
        endpoint = $clusterInfo.endpoint
        version = $clusterInfo.version
        vpc_id = $clusterInfo.resourcesVpcConfig.vpcId
        subnet_ids = @($clusterInfo.resourcesVpcConfig.subnetIds)
        security_group_ids = @($clusterInfo.resourcesVpcConfig.securityGroupIds)
        cluster_security_group_id = $clusterInfo.resourcesVpcConfig.clusterSecurityGroupId
        endpoint_public_access = $clusterInfo.resourcesVpcConfig.endpointPublicAccess
        endpoint_private_access = $clusterInfo.resourcesVpcConfig.endpointPrivateAccess
        public_access_cidrs = @($clusterInfo.resourcesVpcConfig.publicAccessCidrs)
    }
}

function Get-SecurityGroupsEvidence {
    param(
        [Parameter(Mandatory = $false)]
        [string]$VpcId
    )

    Write-Host "[S6] Recogiendo evidencias de grupos de seguridad..." -ForegroundColor Cyan

    if ($VpcId) {
        $securityGroups = Invoke-AwsJson -Arguments @(
            "ec2", "describe-security-groups",
            "--region", $Region,
            "--filters", "Name=vpc-id,Values=$VpcId"
        )
    } else {
        $securityGroups = Invoke-AwsJson -Arguments @(
            "ec2", "describe-security-groups",
            "--region", $Region
        )
    }

    if (-not $securityGroups) {
        return @{
            status = "ERROR"
            message = "No se pudieron listar grupos de seguridad."
            security_groups = @()
        }
    }

    $sgEvidence = @()

    foreach ($sg in $securityGroups.SecurityGroups) {
        $inboundRules = @()
        $outboundRules = @()

        foreach ($perm in $sg.IpPermissions) {
            $fromPort = $null
            $toPort = $null
            if ($perm.PSObject.Properties.Name -contains "FromPort") { $fromPort = $perm.FromPort }
            if ($perm.PSObject.Properties.Name -contains "ToPort") { $toPort = $perm.ToPort }

            $inboundRules += @{
                ip_protocol = $perm.IpProtocol
                from_port = $fromPort
                to_port = $toPort
                ipv4_ranges = @($perm.IpRanges | ForEach-Object { $_.CidrIp })
                ipv6_ranges = @($perm.Ipv6Ranges | ForEach-Object { $_.CidrIpv6 })
                referenced_security_groups = @($perm.UserIdGroupPairs | ForEach-Object { $_.GroupId })
            }
        }

        foreach ($perm in $sg.IpPermissionsEgress) {
            $fromPort = $null
            $toPort = $null
            if ($perm.PSObject.Properties.Name -contains "FromPort") { $fromPort = $perm.FromPort }
            if ($perm.PSObject.Properties.Name -contains "ToPort") { $toPort = $perm.ToPort }

            $outboundRules += @{
                ip_protocol = $perm.IpProtocol
                from_port = $fromPort
                to_port = $toPort
                ipv4_ranges = @($perm.IpRanges | ForEach-Object { $_.CidrIp })
                ipv6_ranges = @($perm.Ipv6Ranges | ForEach-Object { $_.CidrIpv6 })
                referenced_security_groups = @($perm.UserIdGroupPairs | ForEach-Object { $_.GroupId })
            }
        }

        $publicInbound = @(
            $inboundRules | Where-Object {
                $_.ipv4_ranges -contains "0.0.0.0/0" -or $_.ipv6_ranges -contains "::/0"
            }
        )

        $openEgress = @(
            $outboundRules | Where-Object {
                $_.ipv4_ranges -contains "0.0.0.0/0" -or $_.ipv6_ranges -contains "::/0"
            }
        )

        $sgEvidence += @{
            group_id = $sg.GroupId
            group_name = $sg.GroupName
            description = $sg.Description
            vpc_id = $sg.VpcId
            inbound_rule_count = $inboundRules.Count
            outbound_rule_count = $outboundRules.Count
            public_inbound_rule_count = $publicInbound.Count
            open_egress_rule_count = $openEgress.Count
            inbound_rules = $inboundRules
            outbound_rules = $outboundRules
        }
    }

    return @{
        status = "OK"
        description = "Evidencia para S6. Permite comparar exposición pública y reglas de comunicación entre componentes."
        security_group_count = $sgEvidence.Count
        security_groups_with_public_inbound_count = @($sgEvidence | Where-Object { $_.public_inbound_rule_count -gt 0 }).Count
        security_groups_with_open_egress_count = @($sgEvidence | Where-Object { $_.open_egress_rule_count -gt 0 }).Count
        security_groups = $sgEvidence
    }
}

function Get-KubernetesEvidence {
    Write-Host "[S6] Recogiendo evidencias de Kubernetes..." -ForegroundColor Cyan

    if ($SkipKubectl) {
        return @{
            status = "SKIPPED"
            message = "Comprobación kubectl omitida mediante -SkipKubectl."
        }
    }

    $pods = Invoke-KubectlJson -Arguments @(
        "get", "pods",
        "-n", $Namespace
    )

    $services = Invoke-KubectlJson -Arguments @(
        "get", "services",
        "-n", $Namespace
    )

    $ingress = Invoke-KubectlJson -Arguments @(
        "get", "ingress",
        "-n", $Namespace
    )

    $networkPolicies = Invoke-KubectlJson -Arguments @(
        "get", "networkpolicy",
        "-n", $Namespace
    )

    $podEvidence = @()
    $serviceEvidence = @()
    $ingressEvidence = @()
    $networkPolicyEvidence = @()

    if ($pods -and $pods.items) {
        foreach ($pod in $pods.items) {
            $podEvidence += @{
                name = $pod.metadata.name
                status = $pod.status.phase
                labels = $pod.metadata.labels
                node_name = $pod.spec.nodeName
                service_account = $pod.spec.serviceAccountName
            }
        }
    }

    if ($services -and $services.items) {
        foreach ($svc in $services.items) {
            $servicePorts = @()
            foreach ($p in $svc.spec.ports) {
                $portName = $null
                $portNumber = $null
                $targetPort = $null
                $protocol = $null

                if ($p.PSObject.Properties.Name -contains "name") { $portName = $p.name }
                if ($p.PSObject.Properties.Name -contains "port") { $portNumber = $p.port }
                if ($p.PSObject.Properties.Name -contains "targetPort") { $targetPort = $p.targetPort }
                if ($p.PSObject.Properties.Name -contains "protocol") { $protocol = $p.protocol }

                $servicePorts += @{
                    name = $portName
                    port = $portNumber
                    target_port = $targetPort
                    protocol = $protocol
                }
            }

            $serviceEvidence += @{
                name = $svc.metadata.name
                type = $svc.spec.type
                cluster_ip = $svc.spec.clusterIP
                ports = $servicePorts
            }
        }
    }

    if ($ingress -and $ingress.items) {
        foreach ($ing in $ingress.items) {
            $hosts = @()
            if ($ing.spec -and $ing.spec.rules) {
                foreach ($rule in $ing.spec.rules) {
                    $ruleHost = $null
                    if ($rule.PSObject.Properties.Name -contains "host") { $ruleHost = $rule.host }
                    $hosts += $ruleHost
                }
            }

            $ingressEvidence += @{
                name = $ing.metadata.name
                class_name = $ing.spec.ingressClassName
                hosts = $hosts
            }
        }
    }

    if ($networkPolicies -and $networkPolicies.items) {
        foreach ($np in $networkPolicies.items) {
            $networkPolicyEvidence += @{
                name = $np.metadata.name
                pod_selector = $np.spec.podSelector
                policy_types = @($np.spec.policyTypes)
            }
        }
    }

    return @{
        status = "OK"
        description = "Evidencia Kubernetes para S6. Permite ver servicios expuestos y existencia de políticas de red."
        namespace = $Namespace
        pod_count = $podEvidence.Count
        service_count = $serviceEvidence.Count
        ingress_count = $ingressEvidence.Count
        network_policy_count = $networkPolicyEvidence.Count
        pods = $podEvidence
        services = $serviceEvidence
        ingresses = $ingressEvidence
        network_policies = $networkPolicyEvidence
    }
}

Require-Command -Name "aws"

if (-not $SkipKubectl) {
    Require-Command -Name "kubectl"
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

Write-Host "[security_test_2] Entorno: $EnvName" -ForegroundColor Green
Write-Host "[security_test_2] Región AWS: $Region" -ForegroundColor Green
Write-Host "[security_test_2] Cluster EKS: $ClusterName" -ForegroundColor Green

$s4Evidence = Get-InternalAccessEvidence
$iamEvidence = Get-IamRolesEvidence
$eksEvidence = Get-EksClusterEvidence

$vpcId = $null
if ($eksEvidence.status -eq "OK") {
    $vpcId = $eksEvidence.vpc_id
}

$sgEvidence = Get-SecurityGroupsEvidence -VpcId $vpcId
$k8sEvidence = Get-KubernetesEvidence

$s4Status = if ($s4Evidence.status -eq "OK") { "COLLECTED" } elseif ($s4Evidence.status -eq "SKIPPED") { "SKIPPED" } else { "ERROR" }
$s5Status = if ($iamEvidence.status -eq "OK") { "COLLECTED" } else { "ERROR" }
$s6Status = if ($eksEvidence.status -eq "OK" -and $sgEvidence.status -eq "OK") { "COLLECTED" } else { "ERROR" }

$result = @{
    environment = $EnvName
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    region = $Region
    cluster_name = $ClusterName
    namespace = $Namespace
    summary = @{
        total = 3
        collected = @($s4Status, $s5Status, $s6Status | Where-Object { $_ -eq "COLLECTED" }).Count
        skipped = @($s4Status, $s5Status, $s6Status | Where-Object { $_ -eq "SKIPPED" }).Count
        errors = @($s4Status, $s5Status, $s6Status | Where-Object { $_ -eq "ERROR" }).Count
    }
    tests = @(
        @{
            id = "S4"
            name = "Intento de acceso directo a endpoints internos desde el interior"
            status = $s4Status
            objective = "Evaluar movimiento lateral comprobando si un pod interno puede acceder directamente a recursos fuera del flujo previsto (API interna, RDS y S3)."
            evidence = $s4Evidence
        },
        @{
            id = "S5"
            name = "Comprobación de privilegios IAM"
            status = $s5Status
            objective = "Analizar roles y políticas IAM asociadas a la solución para comparar amplitud de permisos entre la solución base y Zero Trust."
            evidence = $iamEvidence
        },
        @{
            id = "S6"
            name = "Comprobación de segmentación y comunicación entre componentes"
            status = $s6Status
            objective = "Analizar grupos de seguridad, exposición de red, configuración del clúster y recursos Kubernetes para comparar la segmentación entre la solución base y Zero Trust."
            evidence = @{
                eks = $eksEvidence
                security_groups = $sgEvidence
                kubernetes = $k8sEvidence
            }
        }
    )
}

$outputPath = Join-Path $OutputDir "security_${EnvName}_2.json"
ConvertTo-JsonFile -Object $result -Path $outputPath

Write-Host "[security_test_2] Evidencia generada en: $outputPath" -ForegroundColor Green

if ($result.summary.errors -gt 0) {
    Write-Host "[security_test_2] Se recogió la evidencia con errores parciales. Revisa el JSON." -ForegroundColor Yellow
    exit 1
}

exit 0
