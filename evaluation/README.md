# Scripts de evaluación

Este directorio contiene los scripts utilizados para evaluar y comparar la solución cloud base y la solución migrada a Zero Trust.

La evaluación se organiza en cuatro bloques:

- Funcionalidad
- Seguridad
- Rendimiento mínimo
- Complejidad, despliegue y coste

El objetivo es ejecutar una baterí­a común de pruebas sobre ambas versiones de la arquitectura y generar evidencias comparables en formato JSON.

## Estructura

```text
evaluation/
├── README.md
├── results/
│   └── base/  almacenamiento de los resultados generados por las pruebas en base
│   └── zt/    almacenamiento de los resultados generados por las pruebas en zt
└── tests/
    ├── functional_test.py
    ├── security_test_1.py
    ├── security_test_2.ps1
    ├── performance_test.py
    └── complexity_test.ps1
```

## 1. Pruebas funcionales

Script:

```text
evaluation/test/functional_test.py
```

Valida que la aplicación cloud desplegada funciona correctamente de extremo a extremo.

Casos cubiertos:

| ID | Prueba |
| --- | --- |
| F1 | Comprobación de disponibilidad (frontend y `GET /api/health`) |
| F2 | Autenticación de usuario (`POST /api/auth/login`) |
| F3 | Creación de evento (`POST /api/events`) |
| F4 | Subida de imagen al evento (`POST /api/events/{id}/image`) |
| F5 | Consulta de evento y estado batch (`GET /api/events/{id}` y `GET /api/batch/status`) |

Parámetros del script:

- `--env` (`base` o `zt`)
- `--base-url`
- `--email`
- `--password`
- `--image-path`
- `--output-dir` (por defecto `evaluation/results`)
- `--trigger-batch-before-pf05` (opcional, dispara un Job manual desde CronJob antes de F5)
- `--k8s-namespace` (por defecto `tfm-app`)
- `--cronjob-name` (por defecto `svc`)
- `--kubectl-timeout-seconds` (por defecto `600`)

Ejemplo de ejecución (base):

```powershell
python .\evaluation\test\functional_test.py `
  --env base `
  --base-url "http://TU-ALB-O-DOMINIO-BASE" `
  --email "admin@example.com" `
  --password "admin123" `
  --image-path ".\evaluation\test\assets\image.jpg"
```

Ejemplo con trigger batch opcional:

```powershell
python .\evaluation\test\functional_test.py `
  --env base `
  --base-url "http://TU-ALB-O-DOMINIO-BASE" `
  --email "admin@example.com" `
  --password "admin123" `
  --image-path ".\evaluation\test\assets\image.jpg" `
  --trigger-batch-before-pf05 `
  --k8s-namespace "tfm-app" `
  --cronjob-name "svc"
```

Para Zero Trust:

TODO

Evidencias generadas:

```text
evaluation/results/base/functional_base.json
evaluation/results/zt/functional_zt.json
```
## 2.1. Pruebas de seguridad de aplicación

Script:

```text
security_test_1.py
```

Valida controles de seguridad a nivel de aplicación/API.

Casos cubiertos:

| ID | Prueba |
| --- | --- |
| S1 | Acceso sin token a endpoint privado |
| S2 | Acceso con token inválido o caducado |
| S3 | Intento de acceso directo a endpoints internos desde el exterior |

Ejemplo de ejecución:

```powershell
python .\evaluation\test\security_test_1.py `
  --env base `
  --base-url "https://TU-ALB-O-DOMINIO-BASE" `
  --db-host "RDS_HOST" `
  --db-port 5432 `
  --s3-bucket "BUCKET" `
  --s3-region "eu-south-2" `
  --s3-test-object-key "events/1/HASH_IMAGEN.jpg"
```

Para Zero Trust:

TODO

Evidencias generadas:

```text
evaluation/results/base/security_base_1.json
evaluation/results/zt/security_zt_1.json
```

## 2.2. Pruebas de seguridad de infraestructura

Script:

```text
security_test_2.ps1
```

Recopila evidencias de seguridad a nivel de infraestructura cloud.

Casos cubiertos:

| ID | Prueba |
| --- | --- |
| S4 | Intento de acceso directo a endpoints internos desde el interior |
| S5 | Comprobación de privilegios IAM |
| S6 | Comprobación de segmentación y comunicación entre componentes |

El script recopila información sobre:

- Movimiento lateral desde un pod temporal de prueba hacia API/RDS/S3.
- Roles IAM relevantes.
- Polí­ticas asociadas a roles.
- Configuración del clúster EKS.
- Grupos de seguridad.
- Reglas de entrada y salida.
- Servicios, pods, ingress y network policies de Kubernetes.

Ejemplo de ejecución:

```powershell
.\evaluation\test\security_test_2.ps1 `
  -EnvName base `
  -Region eu-south-2 `
  -ClusterName tfm-app-eks `
  -Namespace tfm-app `
  -OutputDir "evaluation/results/base" `
  -RdsHost "RDS_HOST" `
  -RdsPort 5432 `
  -S3Bucket "BUCKET" `
  -S3Region "eu-south-2" `
  -S3TestObjectKey "events/1/HASH_IMAGEN.jpg"
```

Para Zero Trust:

TODO

Si no se quiere usar `kubectl`:

```powershell
.\evaluation\test\security_test_2.ps1 `
  -EnvName base `
  -Region eu-south-2 `
  -ClusterName tfm-app-eks `
  -Namespace tfm-app `
  -SkipKubectl
```

Evidencias generadas:

```text
evaluation/results/base/security_base_2.json
evaluation/results/zt/security_zt_2.json
```

## 3. Pruebas de rendimiento mínimo

Script:

```text
evaluation/test/performance_test.py
```

Ejecuta varias repeticiones de operaciones representativas y calcula métricas básicas de tiempo de respuesta.

Casos cubiertos:

| ID | Prueba |
| --- | --- |
| R1 | Tiempo medio de respuesta de un endpoint simple |
| R2 | Tiempo de autenticación de usuario |
| R3 | Tiempo de subida de imagen |

Métricas calculadas:

- Número de iteraciones.
- Peticiones correctas.
- Peticiones fallidas.
- Tiempo mínimo.
- Tiempo máximo.
- Tiempo medio.
- Mediana.
- Percentil 95.

Parámetros del script:

- `--env` (`base` o `zt`)
- `--base-url`
- `--email`
- `--password`
- `--image-path`
- `--iterations` (por defecto `20`)
- `--output-dir` (por defecto `evaluation/results`)

Ejemplo de ejecución (base):

```powershell
python .\evaluation\test\performance_test.py `
  --env base `
  --base-url "http://TU-ALB-O-DOMINIO-BASE" `
  --email "admin@example.com" `
  --password "admin123" `
  --image-path ".\evaluation\test\assets\image.jpg" `
  --iterations 20
```

Para Zero Trust:

TODO

Evidencias generadas:

```text
evaluation/results/base/performance_base.json
evaluation/results/zt/performance_zt.json
```

## 4. Complejidad, despliegue y coste

Script:

```text
evaluation/test/complexity_test.ps1
```

Recopila métricas relacionadas con el esfuerzo técnico, operativo y económico de cada solución.

Casos cubiertos:

| ID | Métrica |
| --- | --- |
| C1 | Tiempo de despliegue |
| C2 | Número de recursos cloud desplegados |
| C3 | Número de políticas IAM, grupos de seguridad y reglas |
| C4 | Líneas de configuración y automatización |
| C5 | Coste mensual teorico |

Costes:

| Servicio | Grupo | Month | Day |
| --- | --- | --- | --- |
| Amazon EKS | base-compute | 73.00 USD/month | 2.43 USD/day |
| Amazon EC2 | base-compute | 35.05 USD/month | 1.17 USD/day |
| Amazon RDS | base-database | 15.68 USD/month | 0.52 USD/day |
| NAT Gateway | base-network | 35.14 USD/month | 1.17 USD/day |
| Application Load Balancer | base-network | 18.63 USD/month | 0.62 USD/day |
| Amazon S3 | base-storage | 0.12 USD/month | 0.004 USD/day |
| Amazon ECR | base-storage | 0.02 USD/month | 0.0007 USD/day |
| Amazon CloudWatch | base-observability | 0.00 USD/month | 0.00 USD/day |

El script recopila información sobre:

- C1: tiempo de despliegue.
  Se calcula exclusivamente a partir de ficheros `deployment_time_<env>*.json` en `evaluation/results/<env>/`.
  Si hay varios ficheros, calcula media, mínimo y máximo.
- C2: recursos Terraform desplegados (`terraform state list`) con desglose por tipo.
- C3: complejidad IAM y Security Groups (filtros por `ProjectKeyword` y entorno).
- C4: líneas de configuración y automatización en Terraform/Kubernetes/scripts.
  Incluye líneas totales y efectivas (sin vacías/comentarios simples), con exclusión de directorios.
- C5: coste teórico diario/mensual.
  Prioriza `cost_estimate_<env>_aws.json` y, si no existe, usa `cost_estimate_<env>_manual.json`.

Parámetros principales:

- `-EnvName` (`base` o `zt`)
- `-Region` (por defecto `eu-south-2`)
- `-TerraformDir` (por defecto `infra/terraform`)
- `-K8sDir` (por defecto `infra/k8s`)
- `-ScriptsDir` (por defecto `scripts`)
- `-OutputDir` (por defecto `evaluation/results`)
- `-ProjectKeyword` (por defecto `tfm`)
- `-ExcludeDirs` (lista de directorios a excluir en C4)

Ejemplo de ejecución:

```powershell
.\evaluation\test\complexity_test.ps1 `
  -EnvName base
```

Para Zero Trust:

TODO

Evidencias generadas:

```text
evaluation/results/base/complexity_base.json
evaluation/results/zt/complexity_zt.json
```

## Dependencias

Para ejecutar los scripts Python:

```powershell
pip install requests
```

Para los scripts PowerShell se requiere:

- AWS CLI configurado.
- Terraform instalado.
- kubectl instalado, salvo que se use `-SkipKubectl`.
- Credenciales AWS con permisos suficientes para consultar IAM, EC2 y EKS.

## Flujo recomendado de ejecución

Para la solución base:

```powershell
python .\evaluation\test\functional_test.py --env base --base-url "http://TU-ALB-O-DOMINIO-BASE" --email "admin@example.com" --password "admin123" --image-path ".\evaluation\test\assets\image.jpg"

python .\evaluation\test\security_test_1.py --env base --base-url "https://TU-ALB-O-DOMINIO-BASE" --db-host "RDS_HOST" --db-port 5432 --s3-bucket "BUCKET" --s3-region "eu-south-2" --s3-test-object-key "events/1/HASH_IMAGEN.jpg"

.\evaluation\test\security_test_2.ps1 -EnvName base -Region eu-south-2 -ClusterName tfm-app-eks -Namespace tfm-app -OutputDir "evaluation/results/base" -RdsHost "RDS_HOST" -RdsPort 5432 -S3Bucket "BUCKET" -S3Region "eu-south-2" -S3TestObjectKey "events/1/HASH_IMAGEN.jpg"

python .\evaluation\test\performance_test.py --env base --base-url "http://TU-ALB-O-DOMINIO-BASE" --email "admin@example.com" --password "admin123" --image-path ".\evaluation\test\assets\image.jpg" --iterations 20

.\evaluation\test\complexity_test.ps1 -EnvName base -Region eu-south-2 -TerraformDir "infra/terraform" -K8sDir "infra/k8s" -ScriptsDir "scripts"
```

Para la solución Zero Trust se repite el mismo flujo cambiando:

```text
--env zt
-EnvName zt
--base-url "https://TODO_ZT_BASE_URL"
```

## Evidencias

Todos los scripts generan ficheros JSON dentro del directorio:

```text
evaluation/results/
```

Estos ficheros se utilizan como evidencia para completar las tablas de resultados del capítulo de evaluación del TFM.

Ejemplo (base):

```text
evaluation/results/base/
├── functional_base.json
├── security_base_1.json
├── security_base_2.json
├── performance_base.json
├── deployment_time_base_1.json
├── deployment_time_base_2.json
├── ...
├── cost_estimate_base_aws.json
├── cost_estimate_base_manual.json
└── complexity_base.json
```

Ejemplo (zt):

```text
evaluation/results/zt/
├── functional_zt.json
├── security_zt_1.json
├── security_zt_2.json
├── performance_zt.json
├── deployment_time_zt_1.json
├── deployment_time_zt_2.json
├── ...
├── cost_estimate_zt_aws.json
├── cost_estimate_zt_manual.json
└── complexity_zt.json
```
