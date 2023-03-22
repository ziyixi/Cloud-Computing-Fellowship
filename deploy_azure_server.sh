# custom configurations
# Azure resource group name
RGNAME="ccf22_xiziyi"
SUBSNAME="Cloud Fellowship"

# Function to check if a list of commands exists, exit script if not
check_commands_exist() {
    for cmd in "$@"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo "$cmd exists"
        else
            echo "$cmd does not exist"
            echo "Exiting script."
            exit 1
        fi
    done
}

# Check if the commands exist
commands=("az" "kubectl" "jq" "kustomize" "kubelogin")
check_commands_exist "${commands[@]}"

# Rest of the script
echo "All commands exist, continuing the script..."

# login to azure
echo "Logging in to Azure..."
az login
az account set --subscription "$SUBSNAME"
echo "Logged in to Azure."

# configure the kubenetes cluster
echo "Configuring the Kubernetes cluster..."
cd kubeflow-aks

SIGNEDINUSER=$(az ad signed-in-user show --query id --out tsv)
DEP=$(az deployment group create -g $RGNAME --parameters signedinuser=$SIGNEDINUSER -f main.bicep -o json)
AKSCLUSTER=$(echo $DEP | jq -r '.properties.outputs.aksClusterName.value')

az aks get-credentials --resource-group $RGNAME --name $AKSCLUSTER --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
echo "Kubernetes cluster is ready to use."
kubectl get nodes

# Install Kubeflow
echo "Installing Kubeflow..."
cd manifests/
while ! kustomize build example | kubectl apply -f -; do
    echo "Retrying to apply resources"
    sleep 10
done

echo "Checking the status of the Kubeflow deployment..."
kubectl get pods -n cert-manager
kubectl get pods -n istio-system
kubectl get pods -n auth
kubectl get pods -n knative-eventing
kubectl get pods -n knative-serving
kubectl get pods -n kubeflow
kubectl get pods -n kubeflow-user-example-com
echo "Kubeflow is ready to use."

# Wait for all required pods to be in the "Running" state
required_namespaces=("cert-manager" "istio-system" "auth" "knative-eventing" "knative-serving" "kubeflow" "kubeflow-user-example-com")

echo "Waiting for all required pods to be running..."

for ns in "${required_namespaces[@]}"; do
    while true; do
        echo "Checking pods in namespace $ns..."
        not_running_pods=$(kubectl get pods -n "$ns" --no-headers | grep -v "Running" | wc -l)
        if [ "$not_running_pods" -eq 0 ]; then
            echo "All pods in namespace $ns are running."
            break
        else
            echo "Some pods are not running in namespace $ns. Retrying in 10 seconds..."
            sleep 10
        fi
    done
done

echo "All required pods are running."

# forward the kubeflow port
echo "Forwarding the Kubeflow port..."
kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80
echo "Enjoy Kubeflow port forwarding!"
