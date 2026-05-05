#!/usr/bin/env bash

set -euo pipefail

ACTION=""
REGION="eu-south-2"
CLUSTER_NAME="tfm-app-eks"
AUTO_APPROVE=false

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "No se encontro el comando '$name'. Instalalo y vuelve a ejecutar." >&2
    exit 1
  fi
}

get_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  while [[ -n "$dir" && ! -d "$dir/infra/terraform" ]]; do
    local parent
    parent="$(dirname "$dir")"
    if [[ "$parent" == "$dir" ]]; then
      echo "No se pudo encontrar la raiz del repositorio. Se esperaba encontrar infra/terraform." >&2
      exit 1
    fi
    dir="$parent"
  done

  echo "$dir"
}

write_section() {
  local text="$1"
  echo ""
  echo "==== $text ===="
}

write_runtime_tfvars() {
  local create_eks="$1"
  local create_rds="$2"
  local create_nat="$3"
  local eks_oidc_issuer_url="${4:-}"
  local repo_root tfvars_path existing

  repo_root="$(get_repo_root)"
  tfvars_path="$repo_root/infra/terraform/runtime.auto.tfvars"

  if [[ -z "$eks_oidc_issuer_url" && -f "$tfvars_path" ]]; then
    existing="$(grep -E '^eks_oidc_issuer_url\s*=' "$tfvars_path" | head -n 1 || true)"
    if [[ -n "$existing" ]]; then
      eks_oidc_issuer_url="$(sed -E 's/^eks_oidc_issuer_url\s*=\s*"([^"]*)".*$/\1/' <<<"$existing")"
    fi
  fi

  {
    echo "create_eks = $create_eks"
    echo "create_rds = $create_rds"
    echo "create_nat = $create_nat"
    if [[ -n "$eks_oidc_issuer_url" ]]; then
      echo "eks_oidc_issuer_url = \"$eks_oidc_issuer_url\""
    fi
  } >"$tfvars_path"

  echo "Escrito $tfvars_path"
}

get_eks_oidc_issuer_url() {
  local region="$1"
  local cluster_name="$2"
  local issuer

  issuer="$(aws eks describe-cluster \
    --region "$region" \
    --name "$cluster_name" \
    --query "cluster.identity.oidc.issuer" \
    --output text)"

  if [[ -z "$issuer" || "$issuer" == "None" ]]; then
    echo "No se pudo obtener el issuer OIDC del cluster $cluster_name" >&2
    exit 1
  fi

  echo "$issuer"
}

invoke_terraform() {
  local repo_root tf_dir
  repo_root="$(get_repo_root)"
  tf_dir="$repo_root/infra/terraform"

  (
    cd "$tf_dir"
    terraform "$@"
  )
}

invoke_kubectl_apply() {
  local repo_root k8s_dir path
  repo_root="$(get_repo_root)"
  k8s_dir="$repo_root/infra/k8s"

  local files=(
    "namespace.yaml"
    "secret.local.yaml"
    "configmap.yaml"
    "api.yaml"
    "svc.yaml"
    "web.yaml"
    "ingress.yaml"
  )

  for file in "${files[@]}"; do
    path="$k8s_dir/$file"
    if [[ -f "$path" ]]; then
      kubectl apply -f "$path"
    else
      echo "WARNING: No existe $path. Se omite." >&2
    fi
  done
}

invoke_kubectl_delete_for_stop() {
  local repo_root k8s_dir path
  repo_root="$(get_repo_root)"
  k8s_dir="$repo_root/infra/k8s"

  local files=(
    "ingress.yaml"
    "web.yaml"
    "api.yaml"
    "svc.yaml"
    "configmap.yaml"
    "aws-lbc-sa.yaml"
    "secret.local.yaml"
  )

  for file in "${files[@]}"; do
    path="$k8s_dir/$file"
    if [[ -f "$path" ]]; then
      kubectl delete -f "$path" --ignore-not-found=true
    else
      echo "WARNING: No existe $path. Se omite." >&2
    fi
  done
}

update_kubeconfig() {
  local region="$1"
  local cluster_name="$2"
  aws eks update-kubeconfig --region "$region" --name "$cluster_name"
}

test_eks_cluster_exists() {
  local region="$1"
  local cluster_name="$2"
  aws eks describe-cluster --region "$region" --name "$cluster_name" >/dev/null 2>&1
}

show_rds_status() {
  local region="$1"
  local instances

  instances="$(aws rds describe-db-instances \
    --region "$region" \
    --query "DBInstances[?DBInstanceIdentifier=='tfm-app-rds'].{id:DBInstanceIdentifier,status:DBInstanceStatus,class:DBInstanceClass,engine:Engine}" \
    --output json)"

  if [[ "$instances" == "[]" || -z "$instances" ]]; then
    echo "Instancia RDS no existe."
    return
  fi

  echo "$instances"
}

show_nat_status() {
  local region="$1"
  local nat_gateways

  nat_gateways="$(aws ec2 describe-nat-gateways \
    --region "$region" \
    --filter "Name=vpc-id,Values=vpc-036af3ec3778f5b1c" \
    --query "NatGateways[?State!='deleted'].{id:NatGatewayId,state:State,subnet:SubnetId}" \
    --output json)"

  if [[ "$nat_gateways" == "[]" || -z "$nat_gateways" ]]; then
    echo "No hay NAT Gateways activas en la VPC."
    return
  fi

  echo "$nat_gateways"
}

repair_private_nat_routes() {
  local region="$1"
  local route_tables=("rtb-027d0f5547df67cd5" "rtb-0bbd08a1834142062")
  local rtb route_state

  for rtb in "${route_tables[@]}"; do
    route_state="$(aws ec2 describe-route-tables \
      --region "$region" \
      --route-table-ids "$rtb" \
      --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'] | [0].State" \
      --output text 2>/dev/null || true)"

    if [[ "$route_state" == "blackhole" ]]; then
      echo "WARNING: Eliminando ruta blackhole 0.0.0.0/0 en $rtb" >&2
      aws ec2 delete-route \
        --region "$region" \
        --route-table-id "$rtb" \
        --destination-cidr-block 0.0.0.0/0
    fi
  done
}

install_load_balancer_controller() {
  local region="$1"
  local cluster_name="$2"

  require_command "helm"

  helm repo add eks https://aws.github.io/eks-charts
  helm repo update

  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$cluster_name" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region="$region" \
    --set vpcId=vpc-036af3ec3778f5b1c
}

wait_for_ingress_address() {
  local namespace="${1:-tfm-app}"
  local ingress_name="${2:-tfm-app-ingress}"
  local timeout_seconds="${3:-600}"
  local elapsed=0
  local address=""

  while (( elapsed < timeout_seconds )); do
    address="$(kubectl -n "$namespace" get ingress "$ingress_name" -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true)"

    if [[ -n "$address" ]]; then
      echo "Ingress disponible: http://$address"
      return
    fi

    echo "Esperando ADDRESS del Ingress... ${elapsed}s/${timeout_seconds}s"
    sleep 15
    elapsed=$((elapsed + 15))
  done

  echo "Timeout esperando ADDRESS del Ingress $ingress_name" >&2
  exit 1
}

invoke_kubectl_apply_file() {
  local file_name="$1"
  local repo_root k8s_dir path

  repo_root="$(get_repo_root)"
  k8s_dir="$repo_root/infra/k8s"
  path="$k8s_dir/$file_name"

  if [[ ! -f "$path" ]]; then
    echo "No existe $path" >&2
    exit 1
  fi

  kubectl apply -f "$path"
}

wait_for_load_balancer_controller() {
  local timeout_seconds="${1:-300}"
  echo "Esperando a que AWS Load Balancer Controller este listo..."
  kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout="${timeout_seconds}s"
}

run_deploy() {
  write_section "Deploy cloud"

  write_section "Activar infraestructura base con coste"
  write_runtime_tfvars "true" "true" "true"

  write_section "Terraform init"
  invoke_terraform init

  write_section "Terraform validate"
  invoke_terraform validate

  write_section "Reparar rutas NAT blackhole previas"
  repair_private_nat_routes "$REGION"

  write_section "Terraform apply infraestructura"
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    invoke_terraform apply -auto-approve
  else
    invoke_terraform apply
  fi

  write_section "Actualizar kubeconfig"
  update_kubeconfig "$REGION" "$CLUSTER_NAME"

  write_section "Detectar OIDC issuer del cluster"
  local oidc_issuer
  oidc_issuer="$(get_eks_oidc_issuer_url "$REGION" "$CLUSTER_NAME")"
  echo "OIDC issuer: $oidc_issuer"

  write_section "Actualizar runtime.auto.tfvars con OIDC"
  write_runtime_tfvars "true" "true" "true" "$oidc_issuer"

  write_section "Terraform apply IAM/OIDC"
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    invoke_terraform apply -auto-approve
  else
    invoke_terraform apply
  fi

  write_section "Aplicar ServiceAccount del Load Balancer Controller"
  invoke_kubectl_apply_file "aws-lbc-sa.yaml"

  write_section "Instalar AWS Load Balancer Controller"
  install_load_balancer_controller "$REGION" "$CLUSTER_NAME"

  write_section "Esperar AWS Load Balancer Controller"
  wait_for_load_balancer_controller

  write_section "Aplicar manifiestos Kubernetes"
  invoke_kubectl_apply

  write_section "Esperar Ingress ALB"
  wait_for_ingress_address

  write_section "Kubernetes status"
  kubectl -n tfm-app get pods,svc,ingress
}

run_stop() {
  write_section "Stop cloud"
  local oidc_issuer=""

  if test_eks_cluster_exists "$REGION" "$CLUSTER_NAME"; then
    write_section "Update kubeconfig"
    update_kubeconfig "$REGION" "$CLUSTER_NAME"

    write_section "Detectar OIDC issuer actual"
    oidc_issuer="$(get_eks_oidc_issuer_url "$REGION" "$CLUSTER_NAME")"
    echo "OIDC issuer: $oidc_issuer"

    write_section "Delete Kubernetes resources"
    invoke_kubectl_delete_for_stop

    echo ""
    echo "Esperando 60 segundos para que AWS Load Balancer Controller elimine recursos externos..."
    sleep 60
  else
    echo "WARNING: El cluster EKS $CLUSTER_NAME no existe. Se omite borrado de manifiestos Kubernetes." >&2
  fi

  write_runtime_tfvars "false" "false" "false" "$oidc_issuer"

  write_section "Terraform apply"
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    invoke_terraform apply -auto-approve
  else
    invoke_terraform apply
  fi
}

run_status() {
  write_section "Terraform state"
  invoke_terraform state list

  write_section "Terraform plan"
  invoke_terraform plan

  write_section "EKS"
  if test_eks_cluster_exists "$REGION" "$CLUSTER_NAME"; then
    aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" --query "cluster.{name:name,status:status,version:version}" --output table

    if update_kubeconfig "$REGION" "$CLUSTER_NAME"; then
      kubectl -n tfm-app get pods,svc,ingress
    else
      echo "WARNING: No se pudo consultar Kubernetes." >&2
    fi
  else
    echo "Cluster EKS no existe."
  fi

  write_section "RDS"
  show_rds_status "$REGION"

  write_section "NAT Gateways"
  show_nat_status "$REGION"
}

usage() {
  cat <<EOF
Uso: $(basename "$0") <deploy|stop|status> [--region REGION] [--cluster-name NAME] [--auto-approve]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    deploy|stop|status)
      if [[ -n "$ACTION" ]]; then
        echo "Accion duplicada: $1" >&2
        usage
        exit 1
      fi
      ACTION="$1"
      shift
      ;;
    --region)
      REGION="${2:-}"
      if [[ -z "$REGION" ]]; then
        echo "Falta valor para --region" >&2
        exit 1
      fi
      shift 2
      ;;
    --cluster-name)
      CLUSTER_NAME="${2:-}"
      if [[ -z "$CLUSTER_NAME" ]]; then
        echo "Falta valor para --cluster-name" >&2
        exit 1
      fi
      shift 2
      ;;
    --auto-approve)
      AUTO_APPROVE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Parametro no reconocido: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$ACTION" ]]; then
  usage
  exit 1
fi

require_command "aws"
require_command "terraform"

case "$ACTION" in
  deploy)
    require_command "kubectl"
    require_command "helm"
    run_deploy
    ;;
  stop)
    require_command "kubectl"
    run_stop
    ;;
  status)
    run_status
    ;;
esac
