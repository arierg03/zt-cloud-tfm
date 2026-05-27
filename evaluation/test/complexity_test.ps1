param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("base", "zt")]
    [string]$EnvName,

    [string]$Region = "eu-south-2",

    [string]$TerraformDir = "infra/terraform",

    [string]$K8sDir = "infra/k8s",

    [string]$ScriptsDir = "scripts",

    [string]$OutputDir = "evaluation/results",

    [string]$ProjectKeyword = "tfm",

    [string[]]$ExcludeDirs = @(".git", ".terraform", ".venv", "venv", "node_modules", "__pycache__", "dist", "build", ".pytest_cache")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "No se encontró el comando '$Name'. Instálalo o añádelo al PATH."
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Object | ConvertTo-Json -Depth 30 | Out-File -FilePath $Path -Encoding utf8
}

function Invoke-JsonCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $raw = & $Command @Arguments --output json 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        return $null
    }

    return $raw | ConvertFrom-Json
}

function Count-Lines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Extensions
    )

    if (-not (Test-Path $Path)) {
        return @{
            path = $Path
            exists = $false
            file_count = 0
            excluded_directories = $ExcludeDirs
            line_count = 0
            line_count_total = 0
            line_count_effective = 0
            files = @()
        }
    }

    $excludedRegex = if ($ExcludeDirs -and $ExcludeDirs.Count -gt 0) {
        '(\\|/)(' + (($ExcludeDirs | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(\\|/)'
    } else {
        $null
    }

    $files = Get-ChildItem -Path $Path -Recurse -File |
        Where-Object {
            if (-not $excludedRegex) { return $true }
            return $_.FullName -notmatch $excludedRegex
        } |
        Where-Object { $Extensions -contains $_.Extension.ToLower() }

    $fileResults = @()
    $totalLines = 0
    $effectiveLines = 0

    foreach ($file in $files) {
        $rawLines = @(Get-Content $file.FullName -ErrorAction SilentlyContinue)
        $lines = @($rawLines).Count
        $nonEmptyNonComment = @(
            $rawLines | Where-Object {
                $trim = $_.Trim()
                if ($trim.Length -eq 0) { return $false }
                if ($trim.StartsWith("#")) { return $false }
                if ($trim.StartsWith("//")) { return $false }
                if ($trim.StartsWith("/*")) { return $false }
                if ($trim.StartsWith("*")) { return $false }
                return $true
            }
        ).Count

        $totalLines += $lines
        $effectiveLines += $nonEmptyNonComment

        $fileResults += @{
            file = $file.FullName
            extension = $file.Extension
            total_lines = $lines
            effective_lines = $nonEmptyNonComment
        }
    }

    return @{
        path = $Path
        exists = $true
        file_count = @($files).Count
        excluded_directories = $ExcludeDirs
        line_count = $effectiveLines
        line_count_total = $totalLines
        line_count_effective = $effectiveLines
        files = $fileResults
    }
}

function Get-TerraformResources {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return @{
            status = "ERROR"
            message = "No existe el directorio Terraform: $Path"
            resource_count = 0
            resources = @()
        }
    }

    Push-Location $Path

    try {
        $workspaceName = & terraform workspace show 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $workspaceName) {
            $workspaceName = "unknown"
        }

        $resources = & terraform state list 2>$null

        if ($LASTEXITCODE -ne 0) {
            return @{
                status = "ERROR"
                message = "No se pudo ejecutar terraform state list. Comprueba que existe estado Terraform."
                workspace = "$workspaceName".Trim()
                resource_count = 0
                managed_resource_count = 0
                data_resource_count = 0
                resource_type_breakdown = @()
                resources = @()
            }
        }

        $resourceList = @($resources)
        $managed = @($resourceList | Where-Object { -not $_.StartsWith("data.") })
        $data = @($resourceList | Where-Object { $_.StartsWith("data.") })

        $typeCounts = @{}
        foreach ($address in $managed) {
            $parts = $address.Split(".")
            $resourceType = $parts[-2]

            if ($typeCounts.ContainsKey($resourceType)) {
                $typeCounts[$resourceType] += 1
            }
            else {
                $typeCounts[$resourceType] = 1
            }
        }

        $breakdown = @(
            $typeCounts.GetEnumerator() |
            Sort-Object -Property Name |
            ForEach-Object {
                @{
                    resource_type = $_.Name
                    count = $_.Value
                }
            }
        )

        return @{
            status = "OK"
            workspace = "$workspaceName".Trim()
            resource_count = $resourceList.Count
            managed_resource_count = $managed.Count
            data_resource_count = $data.Count
            resource_type_breakdown = $breakdown
            resources = $resourceList
        }
    }
    finally {
        Pop-Location
    }
}

function Get-IamComplexity {
    Write-Host "[C3] Recogiendo complejidad IAM..." -ForegroundColor Cyan

    $roles = Invoke-JsonCommand -Command "aws" -Arguments @("iam", "list-roles")

    if (-not $roles) {
        return @{
            status = "ERROR"
            message = "No se pudieron listar roles IAM."
        }
    }

    $envHints = @($EnvName, "$EnvName-", "-$EnvName")
    $patterns = @($ProjectKeyword, "eks", "ecr", "rds", "s3", "alb", "loadbalancer", "node", "cluster") + $envHints
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

        $attached = Invoke-JsonCommand -Command "aws" -Arguments @(
            "iam", "list-attached-role-policies",
            "--role-name", $role.RoleName
        )

        $inline = Invoke-JsonCommand -Command "aws" -Arguments @(
            "iam", "list-role-policies",
            "--role-name", $role.RoleName
        )

        $attachedPolicies = @()
        if ($attached -and $attached.AttachedPolicies) {
            $attachedPolicies = @($attached.AttachedPolicies)
        }

        $inlinePolicies = @()
        if ($inline -and $inline.PolicyNames) {
            $inlinePolicies = @($inline.PolicyNames)
        }

        $relevantRoles += @{
            role_name = $role.RoleName
            arn = $role.Arn
            attached_policy_count = $attachedPolicies.Count
            inline_policy_count = $inlinePolicies.Count
            attached_policies = @($attachedPolicies | ForEach-Object { $_.PolicyName })
            inline_policies = $inlinePolicies
        }
    }

    return @{
        status = "OK"
        relevant_role_count = $relevantRoles.Count
        attached_policy_total = (@($relevantRoles | ForEach-Object { $_.attached_policy_count }) | Measure-Object -Sum).Sum
        inline_policy_total = (@($relevantRoles | ForEach-Object { $_.inline_policy_count }) | Measure-Object -Sum).Sum
        roles = $relevantRoles
    }
}

function Get-SecurityGroupComplexity {
    Write-Host "[C3] Recogiendo complejidad de grupos de seguridad..." -ForegroundColor Cyan

    $securityGroups = Invoke-JsonCommand -Command "aws" -Arguments @(
        "ec2", "describe-security-groups",
        "--region", $Region
    )

    if (-not $securityGroups) {
        return @{
            status = "ERROR"
            message = "No se pudieron listar grupos de seguridad."
        }
    }

    $envHints = @($EnvName, "$EnvName-", "-$EnvName")
    $patterns = @($ProjectKeyword, "eks", "rds", "alb", "loadbalancer", "k8s") + $envHints
    $relevantSg = @()

    foreach ($sg in $securityGroups.SecurityGroups) {
        $nameLower = "$($sg.GroupName) $($sg.Description)".ToLower()
        $isRelevant = $false

        foreach ($pattern in $patterns) {
            if ($nameLower.Contains($pattern)) {
                $isRelevant = $true
                break
            }
        }

        $sgTags = @()
        if ($sg.PSObject.Properties.Name -contains "Tags" -and $null -ne $sg.Tags) {
            $sgTags = @($sg.Tags)
        }

        if (-not $isRelevant -and $sgTags.Count -gt 0) {
            foreach ($tag in $sgTags) {
                $tagPair = "$($tag.Key)=$($tag.Value)".ToLower()
                foreach ($pattern in $patterns) {
                    if ($tagPair.Contains($pattern)) {
                        $isRelevant = $true
                        break
                    }
                }
                if ($isRelevant) {
                    break
                }
            }
        }

        if (-not $isRelevant) {
            continue
        }

        $inboundCount = @($sg.IpPermissions).Count
        $outboundCount = @($sg.IpPermissionsEgress).Count

        $publicInbound = 0

        foreach ($perm in $sg.IpPermissions) {
            foreach ($range in $perm.IpRanges) {
                if ($range.CidrIp -eq "0.0.0.0/0") {
                    $publicInbound++
                }
            }

            foreach ($range in $perm.Ipv6Ranges) {
                if ($range.CidrIpv6 -eq "::/0") {
                    $publicInbound++
                }
            }
        }

        $relevantSg += @{
            group_id = $sg.GroupId
            group_name = $sg.GroupName
            description = $sg.Description
            vpc_id = $sg.VpcId
            inbound_rule_count = $inboundCount
            outbound_rule_count = $outboundCount
            public_inbound_rule_count = $publicInbound
            tags = @(
                @($sgTags | ForEach-Object {
                    @{
                        key = $_.Key
                        value = $_.Value
                    }
                })
            )
        }
    }

    return @{
        status = "OK"
        security_group_count = $relevantSg.Count
        inbound_rule_total = (@($relevantSg | ForEach-Object { $_.inbound_rule_count }) | Measure-Object -Sum).Sum
        outbound_rule_total = (@($relevantSg | ForEach-Object { $_.outbound_rule_count }) | Measure-Object -Sum).Sum
        public_inbound_rule_total = (@($relevantSg | ForEach-Object { $_.public_inbound_rule_count }) | Measure-Object -Sum).Sum
        security_groups = $relevantSg
    }
}

function Get-MonthlyCost {
    $resolvedDir = Join-Path $OutputDir $EnvName
    $manualEstimatePath = Join-Path $resolvedDir "cost_estimate_$EnvName`_manual.json"
    $awsEstimatePath = Join-Path $resolvedDir "cost_estimate_$EnvName`_aws.json"

    if (Test-Path $awsEstimatePath) {
        try {
            $raw = Get-Content -Path $awsEstimatePath -Raw -Encoding utf8
            $awsEstimate = $raw | ConvertFrom-Json

            $monthlyTotal = [double]$awsEstimate.totalCostEstimated
            $daysPerMonth = 30.0
            $dailyTotal = $monthlyTotal / $daysPerMonth

            $byService = @(
                @($awsEstimate.items) |
                Group-Object -Property serviceCode |
                ForEach-Object {
                    $serviceMonthly = (@($_.Group | ForEach-Object { [double]$_.costSummary.cost }) | Measure-Object -Sum).Sum
                    @{
                        service = $_.Name
                        monthly_estimated_cost = [math]::Round([double]$serviceMonthly, 4)
                        daily_estimated_cost = [math]::Round(([double]$serviceMonthly / $daysPerMonth), 4)
                    }
                } |
                Sort-Object -Property monthly_estimated_cost -Descending
            )

            $byGroup = @(
                @($awsEstimate.items) |
                Group-Object -Property group |
                ForEach-Object {
                    $groupMonthly = (@($_.Group | ForEach-Object { [double]$_.costSummary.cost }) | Measure-Object -Sum).Sum
                    @{
                        group = $_.Name
                        monthly_estimated_cost = [math]::Round([double]$groupMonthly, 4)
                        daily_estimated_cost = [math]::Round(([double]$groupMonthly / $daysPerMonth), 4)
                    }
                } |
                Sort-Object -Property monthly_estimated_cost -Descending
            )

            return @{
                status = "OK"
                source = "theoretical_aws_export"
                estimate_file = $awsEstimatePath
                currency = $awsEstimate.currency
                days_per_month = $daysPerMonth
                monthly_estimated_cost = [math]::Round($monthlyTotal, 4)
                daily_estimated_cost = [math]::Round($dailyTotal, 4)
                by_group = $byGroup
                by_service = $byService
            }
        }
        catch {
            return @{
                status = "ERROR"
                source = "theoretical_aws_export"
                estimate_file = $awsEstimatePath
                message = "No se pudo parsear el JSON exportado del AWS Pricing Calculator."
            }
        }
    }

    if (Test-Path $manualEstimatePath) {
        try {
            $raw = Get-Content -Path $manualEstimatePath -Raw -Encoding utf8
            $manual = $raw | ConvertFrom-Json

            $monthlyTotal = 0.0
            $dailyTotal = 0.0
            $byService = @()
            $groupTotals = @{}

            foreach ($item in @($manual.items)) {
                $monthly = [double]$item.monthly_estimated_cost
                $daily = [double]$item.daily_estimated_cost
                $monthlyTotal += $monthly
                $dailyTotal += $daily

                $byService += @{
                    service = $item.service
                    component = $item.component
                    group = $item.group
                    monthly_estimated_cost = $monthly
                    daily_estimated_cost = $daily
                }

                $groupName = "$($item.group)"
                if (-not $groupTotals.ContainsKey($groupName)) {
                    $groupTotals[$groupName] = 0.0
                }
                $groupTotals[$groupName] += $monthly
            }

            $byGroup = @(
                $groupTotals.GetEnumerator() |
                Sort-Object -Property Value -Descending |
                ForEach-Object {
                    @{
                        group = $_.Key
                        monthly_estimated_cost = [math]::Round([double]$_.Value, 4)
                        daily_estimated_cost = [math]::Round(([double]$_.Value / [double]$manual.days_per_month), 4)
                    }
                }
            )

            return @{
                status = "OK"
                source = "theoretical_manual"
                estimate_file = $manualEstimatePath
                currency = $manual.currency
                days_per_month = $manual.days_per_month
                monthly_estimated_cost = [math]::Round($monthlyTotal, 4)
                daily_estimated_cost = [math]::Round($dailyTotal, 4)
                by_group = $byGroup
                by_service = $byService
            }
        }
        catch {
            return @{
                status = "ERROR"
                source = "theoretical_manual"
                estimate_file = $manualEstimatePath
                message = "No se pudo parsear el JSON de coste manual."
            }
        }
    }

    return @{
        status = "ERROR"
        message = "No se encontraron ficheros de coste teórico. Esperado: cost_estimate_<env>_aws.json o cost_estimate_<env>_manual.json."
    }
}

function Get-C3Status {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Iam,
        [Parameter(Mandatory = $true)][hashtable]$SecurityGroups
    )

    if ($Iam.status -eq "ERROR" -or $SecurityGroups.status -eq "ERROR") {
        return "ERROR"
    }

    return "COLLECTED"
}

function Get-DeploymentEvidence {
    $resolvedDir = Join-Path $OutputDir $EnvName
    $evidenceFiles = @()

    if (Test-Path $resolvedDir) {
        $evidenceFiles = @(
            Get-ChildItem -Path $resolvedDir -File -Filter "deployment_time_$EnvName*.json" |
            Sort-Object -Property LastWriteTime
        )
    }

    if ($evidenceFiles.Count -gt 0) {
        $durations = @()
        $validFiles = @()

        foreach ($file in $evidenceFiles) {
            try {
                $raw = Get-Content -Path $file.FullName -Raw -Encoding utf8
                $data = $raw | ConvertFrom-Json
                if ($null -ne $data.deployment_seconds) {
                    $durations += [double]$data.deployment_seconds
                    $validFiles += $file.FullName
                }
            }
            catch {
                continue
            }
        }

        if ($durations.Count -gt 0) {
            $avgSeconds = [math]::Round((($durations | Measure-Object -Average).Average), 2)
            $minSeconds = [math]::Round((($durations | Measure-Object -Minimum).Minimum), 2)
            $maxSeconds = [math]::Round((($durations | Measure-Object -Maximum).Maximum), 2)

            return @{
                status = "PROVIDED"
                source = "deployment_evidence_files_aggregate"
                sample_count = $durations.Count
                evidence_files = $validFiles
                deployment_seconds = $avgSeconds
                deployment_minutes = [math]::Round($avgSeconds / 60, 2)
                deployment_seconds_min = $minSeconds
                deployment_seconds_max = $maxSeconds
            }
        }
    }

    return @{
        status = "NOT_PROVIDED"
        message = "No se encontraron ficheros deployment_time_<env>*.json para calcular C1."
    }
}

Require-Command -Name "aws"
Require-Command -Name "terraform"

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host "[complexity_test] Entorno: $EnvName" -ForegroundColor Green

$resolvedOutputDir = Join-Path $OutputDir $EnvName
if (-not (Test-Path $resolvedOutputDir)) {
    New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
}

$terraformResources = Get-TerraformResources -Path $TerraformDir

$terraformLoc = Count-Lines -Path $TerraformDir -Extensions @(".tf", ".tfvars")
$k8sLoc = Count-Lines -Path $K8sDir -Extensions @(".yaml", ".yml")
$scriptsLoc = Count-Lines -Path $ScriptsDir -Extensions @(".ps1", ".sh", ".py")

$iamComplexity = Get-IamComplexity
$sgComplexity = Get-SecurityGroupComplexity
$c3Status = Get-C3Status -Iam $iamComplexity -SecurityGroups $sgComplexity
$monthlyCost = Get-MonthlyCost

$deployment = Get-DeploymentEvidence

$result = @{
    environment = $EnvName
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    region = $Region
    tests = @(
        @{
            id = "C1"
            name = "Tiempo de despliegue"
            status = $deployment.status
            evidence = $deployment
        },
        @{
            id = "C2"
            name = "Número de recursos cloud desplegados"
            status = $terraformResources.status
            evidence = $terraformResources
        },
        @{
            id = "C3"
            name = "Número de polí­ticas IAM, grupos de seguridad y reglas"
            status = $c3Status
            evidence = @{
                filters = @{
                    project_keyword = $ProjectKeyword
                    environment = $EnvName
                }
                iam = $iamComplexity
                security_groups = $sgComplexity
            }
        },
        @{
            id = "C4"
            name = "Lí­neas de configuración y automatización"
            status = "COLLECTED"
            evidence = @{
                terraform = $terraformLoc
                kubernetes = $k8sLoc
                scripts = $scriptsLoc
                total_line_count = $terraformLoc.line_count_total + $k8sLoc.line_count_total + $scriptsLoc.line_count_total
                total_effective_line_count = $terraformLoc.line_count_effective + $k8sLoc.line_count_effective + $scriptsLoc.line_count_effective
                excluded_directories = $ExcludeDirs
                total_file_count = $terraformLoc.file_count + $k8sLoc.file_count + $scriptsLoc.file_count
            }
        },
        @{
            id = "C5"
            name = "Coste mensual teorico"
            status = $monthlyCost.status
            evidence = $monthlyCost
        }
    )
}

$outputPath = Join-Path $resolvedOutputDir "complexity_$EnvName.json"
Write-JsonFile -Object $result -Path $outputPath

Write-Host "[complexity_test] Evidencia generada en: $outputPath" -ForegroundColor Green

exit 0

