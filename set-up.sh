#!/bin/bash
# deploy_moodle_minikube_reset.sh
# Script to reset and redeploy Moodle and PostgreSQL on Minikube

set -e

NAMESPACE="moodle"
CLUSTER_NAME="minikube"

# 0. Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "kubectl not found. Installing..."
    curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    echo "✅ kubectl installed successfully."
else
    echo "✅ kubectl already installed."
fi

# 1. Check Minikube cluster status
if ! command -v minikube &> /dev/null; then
    echo "Minikube not found. Please install Minikube first:"
    echo "  https://minikube.sigs.k8s.io/docs/start/"
    exit 1
fi

if ! minikube status >/dev/null 2>&1; then
    echo "Minikube is not running. Creating and starting cluster..."
    minikube start --driver=docker --profile $CLUSTER_NAME
else
    echo "✅ Minikube is running, profile: $CLUSTER_NAME"
fi

# 2. Switch kubectl to Minikube context and namespace
kubectl config use-context minikube
kubectl config set-context --current --namespace=$NAMESPACE

# 3. Delete existing resources
echo "🧹 Deleting existing resources if any..."
FILES=("3_moodle.yaml" "2_psql_db.yaml" "1_moodle_pvc.yaml" "0_secret.yaml")

for f in "${FILES[@]}"; do
    if [ -f "$f" ]; then
        kubectl delete -f "$f" --ignore-not-found
    fi
done

# 4. Deploy new resources in correct order
echo "🚀 Deploying new resources..."
for f in "0_secret.yaml" "1_moodle_pvc.yaml" "2_psql_db.yaml" "3_moodle.yaml"; do
    if [ -f "$f" ]; then
        kubectl apply -f "$f"
    fi
done

# 5. Display status
echo "✅ Deployment completed."
echo "🔍 Checking Pods and Services:"
kubectl get all -n $NAMESPACE
