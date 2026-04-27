#!/usr/bin/env bash
set -euo pipefail

REGION="eu-south-2"
ACCOUNT_ID=""
REPOSITORY_PREFIX="zt"
TAG=""
SERVICES_CSV="api,web,svc"
PLATFORM="linux/amd64"
WEB_API_URL="/api"
NO_CACHE=false
SKIP_LATEST=false

usage() {
  cat <<'EOF'
Uso:
  ./scripts/update-images.sh [opciones]

Opciones:
  --region <region>                 Region AWS (default: eu-south-2)
  --account-id <id>                 AWS Account ID (si se omite, se autodetecta)
  --repository-prefix <prefix>      Prefijo repos ECR (default: zt)
  --tag <tag>                       Tag de imagen (si se omite: yyyyMMdd-HHmmss)
  --services <lista>                Servicios separados por coma (api,web,svc)
  --platform <platform>             Plataforma Docker buildx (default: linux/amd64)
  --web-api-url <url>               Build arg VITE_API_URL para web (default: /api)
  --no-cache                        Build sin cache
  --skip-latest                     No publicar tag latest
  -h, --help                        Mostrar ayuda

Ejemplos:
  ./scripts/update-images.sh
  ./scripts/update-images.sh --tag v1.0.0
  ./scripts/update-images.sh --services api,svc --no-cache
  ./scripts/update-images.sh --region eu-south-2 --account-id 296368270177
EOF
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "No se encontro el comando '$name'. Instalalo y vuelve a ejecutar." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGION="${2:-}"; shift 2 ;;
    --account-id)
      ACCOUNT_ID="${2:-}"; shift 2 ;;
    --repository-prefix)
      REPOSITORY_PREFIX="${2:-}"; shift 2 ;;
    --tag)
      TAG="${2:-}"; shift 2 ;;
    --services)
      SERVICES_CSV="${2:-}"; shift 2 ;;
    --platform)
      PLATFORM="${2:-}"; shift 2 ;;
    --web-api-url)
      WEB_API_URL="${2:-}"; shift 2 ;;
    --no-cache)
      NO_CACHE=true; shift ;;
    --skip-latest)
      SKIP_LATEST=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Argumento no reconocido: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_command aws
require_command docker

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

if [[ -z "$TAG" ]]; then
  TAG="$(date +%Y%m%d-%H%M%S)"
fi

if [[ -z "$ACCOUNT_ID" ]]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text | tr -d '[:space:]')"
fi

if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
  echo "No se pudo resolver AccountId. Pasa --account-id o revisa tu AWS CLI profile." >&2
  exit 1
fi

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Login en ECR: ${REGISTRY}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

IFS=',' read -r -a SERVICES <<< "$SERVICES_CSV"

declare -a RESULT_LINES
RESULT_LINES+=("service|tag|image|latest")

for service in "${SERVICES[@]}"; do
  service="$(echo "$service" | xargs)"
  case "$service" in
    api)
      context="app/api"
      dockerfile="app/api/Dockerfile"
      build_args=()
      ;;
    web)
      context="app/web"
      dockerfile="app/web/Dockerfile"
      build_args=(--build-arg "VITE_API_URL=${WEB_API_URL}")
      ;;
    svc)
      context="app/svc"
      dockerfile="app/svc/Dockerfile"
      build_args=()
      ;;
    *)
      echo "Servicio desconocido: $service" >&2
      exit 1
      ;;
  esac

  repo_name="${REPOSITORY_PREFIX}/${service}"
  image_base="${REGISTRY}/${repo_name}"
  tagged_image="${image_base}:${TAG}"
  latest_image="${image_base}:latest"

  echo
  echo "Comprobando repositorio ECR: ${repo_name}"
  aws ecr describe-repositories --region "$REGION" --repository-names "$repo_name" >/dev/null

  build_cmd=(
    docker buildx build
    --platform "$PLATFORM"
    --provenance=false
    --sbom=false
    --load
    -f "$dockerfile"
    -t "$tagged_image"
  )

  if [[ "$SKIP_LATEST" == false ]]; then
    build_cmd+=(-t "$latest_image")
  fi
  if [[ "$NO_CACHE" == true ]]; then
    build_cmd+=(--no-cache)
  fi
  if [[ "${#build_args[@]}" -gt 0 ]]; then
    build_cmd+=("${build_args[@]}")
  fi
  build_cmd+=("$context")

  echo "Building $service -> $tagged_image"
  "${build_cmd[@]}"

  echo "Pushing $tagged_image"
  docker push "$tagged_image"

  if [[ "$SKIP_LATEST" == false ]]; then
    echo "Pushing $latest_image"
    docker push "$latest_image"
    latest_display="$latest_image"
  else
    latest_display="(omitido)"
  fi

  RESULT_LINES+=("${service}|${TAG}|${tagged_image}|${latest_display}")
done

echo
echo "Imagenes actualizadas en ECR:"
printf "%-8s %-18s %-90s %s\n" "service" "tag" "image" "latest"
for line in "${RESULT_LINES[@]:1}"; do
  IFS='|' read -r c_service c_tag c_image c_latest <<< "$line"
  printf "%-8s %-18s %-90s %s\n" "$c_service" "$c_tag" "$c_image" "$c_latest"
done

