#!/bin/bash
set -euo pipefail

trap handle_errors ERR

handle_errors() {
    echo "Erro detectado durante a operação!"
    exit 1
}

# ----------------------------------------
# Funções de Verificação
# ----------------------------------------

verify_tools_installed() {
    tools=("aws" "helm" "kubectl" "eksctl")

    for tool in "${tools[@]}"; do
        echo "Verificando instalação do $tool..."
        if ! command -v $tool &>/dev/null; then
            echo "Erro: $tool não está instalado."
            exit 1
        fi
    done
    echo "Todas as ferramentas necessárias estão instaladas."
}


verify_aws_credentials() {
    echo "Verificando credenciais da AWS..."
    if ! aws sts get-caller-identity &>/dev/null; then
        echo "Erro: Credenciais da AWS não encontradas ou são inválidas."
        exit 1
    fi
}

verify_helm() {
    echo "Verificando instalação do Helm..."
    if ! command -v helm &>/dev/null; then
        echo "Erro: Helm não está instalado."
        exit 1
    fi
}

verify_eks_cluster() {
    echo "Verificando o cluster EKS..."
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.status" --output text | grep -q "ACTIVE"; then
        echo "Erro: Cluster EKS '$CLUSTER_NAME' não está ativo ou não existe."
        exit 1
    fi
}

helm_release_exists() {
    helm list -q --all-namespaces | grep -q "$1"
}

grant_aws_root_access() {
    echo "Concedendo acesso de administrador ao usuário root da AWS..."
    kubectl get configmap aws-auth -n kube-system -o yaml > /tmp/original-aws-auth-configmap.yaml

    awk '/mapRoles: \|/ { print; print "    - rolearn: arn:aws:iam::'$ACCOUNT_ID':root\n      username: admin\n      groups:\n        - system:masters"; next }1' /tmp/original-aws-auth-configmap.yaml > /tmp/modified-aws-auth-configmap.yaml

    if kubectl apply -f /tmp/modified-aws-auth-configmap.yaml; then
        echo "ConfigMap aws-auth atualizado com sucesso!"
        rm /tmp/original-aws-auth-configmap.yaml /tmp/modified-aws-auth-configmap.yaml
    else
        echo "Erro ao atualizar o ConfigMap aws-auth. Restaurando o original..."
        kubectl apply -f /tmp/original-aws-auth-configmap.yaml
        rm /tmp/original-aws-auth-configmap.yaml /tmp/modified-aws-auth-configmap.yaml
        exit 1
    fi
}

check_pod_health() {
    local namespace=$1
    local label_selector=$2

    local max_attempts=10
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        echo "Verificando saúde dos pods ($attempt/$max_attempts)..."
        
        local unhealthy_pods=$(kubectl get pods -n $namespace -l $label_selector --no-headers=true | grep -Evi 'running|completed' | wc -l)
        if [[ $unhealthy_pods -eq 0 ]]; then
            echo "Todos os pods estão saudáveis!"
            return 0
        fi

        attempt=$((attempt+1))
        sleep 15
    done

    echo "Erro: Nem todos os pods estão saudáveis após $max_attempts tentativas."
    exit 1
}

# ----------------------------------------
# Definição de Variáveis
# ----------------------------------------

CLUSTER_NAME="cluster-name"
REGION="us-east-1"
ACCOUNT_ID=""
DOMAIN="example.com"
AWS_ACCESS_KEY=""
AWS_SECRET_KEY=""
STORAGE_CLASS="gp2"
GRAFANA_SUBDOMAIN="grafana.example.com"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD="teste@2023!"
ALB_NAME="alb-public"

# ----------------------------------------
# Verificações Preliminares
# ----------------------------------------

verify_aws_credentials
verify_helm
verify_eks_cluster
verify_tools_installed

# ----------------------------------------
# Configuração do AWS CLI
# ----------------------------------------

echo "Configurando AWS CLI..."
aws configure set aws_access_key_id "$AWS_ACCESS_KEY"
aws configure set aws_secret_access_key "$AWS_SECRET_KEY"
aws configure set default.region "$REGION"

# ----------------------------------------
# Instalação e Configuração
# ----------------------------------------

echo "Configurando repositórios Helm..."
helm repo add jetstack https://charts.jetstack.io
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add eks https://aws.github.io/eks-charts
helm repo update

echo "Associando OIDC provider ao EKS..."
eksctl utils associate-iam-oidc-provider \
  --region $REGION \
  --name $CLUSTER_NAME \
  --approve

# ----------------------------------------
# Instalação do Metrics Server
# ----------------------------------------

if ! helm_release_exists "metrics-server"; then
    echo "Instalando Metrics Server..."
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
    helm install metrics-server metrics-server/metrics-server \
      --namespace kube-system \
      --create-namespace
    check_pod_health "kube-system" "app.kubernetes.io/name=metrics-server"
else
    echo "Metrics Server já está instalado. "
fi

# ----------------------------------------
# Instalação do cert-manager
# ----------------------------------------

if ! helm_release_exists "cert-manager"; then
    echo "Instalando cert-manager..."
    helm install cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --create-namespace \
      --version v1.13.0 \
      --set installCRDs=true
    check_pod_health "cert-manager" "app.kubernetes.io/name=cert-manager"
else
    echo "cert-manager já está instalado. "
fi

# ----------------------------------------
# Instalação do External-DNS
# ----------------------------------------

if ! helm_release_exists "external-dns"; then
    echo "Instalando External-DNS..."
    helm install external-dns bitnami/external-dns \
      --set provider=aws \
      --set txtOwnerId=$CLUSTER_NAME \
      --set domainFilters[0]=$DOMAIN
else
    echo "External-DNS já está instalado. "
fi

# ----------------------------------------
# Instalação do AWS Load Balancer Controller
# ----------------------------------------

IAM_POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy"

echo "Configurando IAM service account para o AWS Load Balancer Controller..."
eksctl create iamserviceaccount \
  --region $REGION \
  --name aws-load-balancer-controller \
  --namespace kube-system \
  --cluster $CLUSTER_NAME \
  --attach-policy-arn $IAM_POLICY_ARN \
  --approve

if ! helm_release_exists "aws-load-balancer-controller"; then
    echo "Instalando AWS Load Balancer Controller..."
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName=$CLUSTER_NAME \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set region=$REGION
    check_pod_health "kube-system" "app.kubernetes.io/name=aws-load-balancer-controller"
else
    echo "AWS Load Balancer Controller já está instalado. "
fi

# ----------------------------------------
# Instalação do kube-state-metrics
# ----------------------------------------

if ! helm_release_exists "kube-state-metrics"; then
    echo "Instalando kube-state-metrics..."
    helm install kube-state-metrics bitnami/kube-state-metrics
else
    echo "kube-state-metrics já está instalado."
fi

# ----------------------------------------
# Instalação do Prometheus com Persistência
# ----------------------------------------

if ! helm_release_exists "prometheus"; then
    echo "Instalando Prometheus..."
    helm install prometheus bitnami/kube-prometheus \
      --set server.persistence.enabled=true \
      --set server.persistence.storageClass=$STORAGE_CLASS
    check_pod_health "default" "app.kubernetes.io/name=prometheus"
else
    echo "Prometheus já está instalado."
fi

# ----------------------------------------
# Instalação do Grafana com Persistência
# ----------------------------------------
#if ! helm_release_exists "grafana"; then
#   echo "Instalando Grafana..."
#   helm install grafana bitnami/grafana \
#     --values grafana/grafana-values.yaml
#    check_pod_health "default" "app.kubernetes.io/name=grafana"
#else
#    echo "Grafana já está instalado."
#fi

# ----------------------------------------
# Concede ao usuário root da AWS acesso de administrador ao cluster
# ----------------------------------------

#grant_aws_root_access

echo "Todas as instalações e configurações foram concluídas!"
