#!/bin/bash
# Script to reset and redeploy Moodle, PostgreSQL, and Ingress on Azure AKS
set -e

NAMESPACE="moodle"
CLUSTER_NAME="moodle-cluster"
RESOURCE_GROUP="moodle-rg"
LOCATION="southeastasia"  # Thay đổi location nếu cần (gần Việt Nam nhất)
NODE_COUNT=2
NODE_SIZE="Standard_B2s"  # Có thể thay đổi: Standard_D2s_v3, Standard_B2ms, etc.

# 0. Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo "🔧 Azure CLI not found. Installing..."
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    echo "✅ Azure CLI installed successfully."
else
    echo "✅ Azure CLI already installed."
fi

# 1. Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "🔧 kubectl not found. Installing..."
    curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    echo "✅ kubectl installed successfully."
else
    echo "✅ kubectl already installed."
fi

# 2. Login to Azure (skip if already logged in)
echo "🔐 Checking Azure login status..."
if ! az account show &> /dev/null; then
    echo "🔐 Please login to Azure..."
    az login
else
    echo "✅ Already logged in to Azure."
    echo "📋 Current subscription: $(az account show --query name -o tsv)"
fi

# 3. Create Resource Group if it doesn't exist
echo "🔍 Checking if resource group exists..."
RG_EXISTS=$(az group exists --name $RESOURCE_GROUP)
if [ "$RG_EXISTS" = "false" ]; then
    echo "🏗️  Creating resource group: $RESOURCE_GROUP in $LOCATION..."
    az group create --name $RESOURCE_GROUP --location $LOCATION
    echo "✅ Resource group created successfully."
else
    echo "✅ Resource group $RESOURCE_GROUP already exists."
fi

# 4. Create AKS cluster if it doesn't exist
echo "🔍 Checking if AKS cluster exists..."
AKS_EXISTS=$(az aks list --resource-group $RESOURCE_GROUP --query "[?name=='$CLUSTER_NAME'].name" -o tsv 2>/dev/null || echo "")
if [ -z "$AKS_EXISTS" ]; then
    echo "🚀 Creating AKS cluster: $CLUSTER_NAME..."
    echo "⏳ This may take 5-10 minutes..."
    az aks create \
        --resource-group $RESOURCE_GROUP \
        --name $CLUSTER_NAME \
        --node-count $NODE_COUNT \
        --node-vm-size $NODE_SIZE \
        --enable-addons monitoring \
        --generate-ssh-keys \
        --network-plugin azure \
        --network-policy azure
    echo "✅ AKS cluster created successfully."
else
    echo "✅ AKS cluster $CLUSTER_NAME already exists."
fi

# 5. Get AKS credentials (only if cluster exists)
echo "🔗 Getting AKS credentials for cluster: $CLUSTER_NAME"
if az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME &> /dev/null; then
    az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --overwrite-existing
else
    echo "❌ Error: AKS cluster does not exist. Please check the cluster creation step."
    exit 1
fi

# 6. Create namespace if it doesn't exist
echo "🔍 Checking namespace..."
if ! kubectl get namespace $NAMESPACE &> /dev/null; then
    echo "📦 Creating namespace: $NAMESPACE"
    kubectl create namespace $NAMESPACE
else
    echo "✅ Namespace $NAMESPACE already exists."
fi

# 7. Switch kubectl context to AKS cluster and namespace
kubectl config use-context $CLUSTER_NAME
kubectl config set-context --current --namespace=$NAMESPACE

# 8. Install NGINX Ingress Controller if not already installed
echo "🔍 Checking for NGINX Ingress Controller..."
if ! kubectl get namespace ingress-nginx &> /dev/null; then
    echo "🔧 Installing NGINX Ingress Controller..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
    
    echo "⏳ Waiting for NGINX Ingress controller to be ready..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=300s
    
    echo "✅ NGINX Ingress Controller installed."
else
    echo "✅ NGINX Ingress Controller already installed."
fi

# 9. Delete existing resources (reverse order)
echo "🧹 Deleting existing resources if any..."
FILES=("4_moodle_ingress.yaml" "3_moodle.yaml" "2_psql_db.yaml" "1_moodle_pvc.yaml" "0_secret.yaml")
for f in "${FILES[@]}"; do
    if [ -f "$f" ]; then
        kubectl delete -f "$f" --ignore-not-found --namespace=$NAMESPACE
    fi
done

# 10. Deploy new resources in correct order
echo "🚀 Deploying new resources..."
DEPLOY_ORDER=("0_secret.yaml" "1_moodle_pvc.yaml" "2_psql_db.yaml" "3_moodle.yaml" "4_moodle_ingress.yaml")
for f in "${DEPLOY_ORDER[@]}"; do
    if [ -f "$f" ]; then
        kubectl apply -f "$f" --namespace=$NAMESPACE
    fi
done

# 11. Wait for Ingress to get external IP
echo "⏳ Waiting for Ingress to get external IP address..."
echo "   This may take a few minutes..."
for i in {1..30}; do
    EXTERNAL_IP=$(kubectl get ingress -n $NAMESPACE -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
        break
    fi
    echo "   Attempt $i/30: Waiting for external IP..."
    sleep 10
done

# 12. Display status
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "✅ Deployment completed successfully!"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "🔍 Cluster Information:"
echo "   Resource Group: $RESOURCE_GROUP"
echo "   Cluster Name: $CLUSTER_NAME"
echo "   Namespace: $NAMESPACE"
echo ""
echo "🔍 Resources Status:"
kubectl get all -n $NAMESPACE
echo ""
echo "🌐 Ingress Status:"
kubectl get ingress -n $NAMESPACE

if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "🎉 Your Moodle is accessible at:"
    echo "   http://$EXTERNAL_IP"
    echo "═══════════════════════════════════════════════════════════"
else
    echo ""
    echo "⚠️  External IP not yet assigned. Run this command to check:"
    echo "   kubectl get ingress -n $NAMESPACE"
fi

echo ""
echo "📝 Useful commands:"
echo "   View pods: kubectl get pods -n $NAMESPACE"
echo "   View logs: kubectl logs -f <pod-name> -n $NAMESPACE"
echo "   Delete cluster: az aks delete --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --yes --no-wait"
echo "   Delete resource group: az group delete --name $RESOURCE_GROUP --yes --no-wait"