# * custom configurations
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

# * generate password hash
# Check if Passlib is installed
python -c "import passlib; import bcrypt" &>/dev/null

if [ $? -eq 0 ]; then
    PYTHON_CMD=$(
        cat <<EOF
import getpass
from passlib.hash import bcrypt

password = getpass.getpass()
hashed_password = bcrypt.using(rounds=12, ident="2y").hash(password)
print(hashed_password)
EOF
    )

    # Store the hashed password in the HASHED_PASSWORD environment variable
    export HASHED_PASSWORD=$(echo "$PYTHON_CMD" | python)
    # Escape special characters in the hashed password and remove square brackets
    HASHED_PASSWORD=$(echo "$HASHED_PASSWORD" | sed 's/[\$\[\]]/\\&/g')
    echo "Hashed password stored in the HASHED_PASSWORD environment variable as $HASHED_PASSWORD."
else
    echo "Passlib or bcrypt is not installed. Please install it using 'pip install passlib bcrypt' and try again."
    exit 1
fi

# * login to azure
echo "Logging in to Azure..."
az login
az account set --subscription "$SUBSNAME"
echo "Logged in to Azure."

# * configure the kubenetes cluster
echo "Configuring the Kubernetes cluster..."
cd kubeflow-aks

SIGNEDINUSER=$(az ad signed-in-user show --query id --out tsv)
DEP=$(az deployment group create -g $RGNAME --parameters signedinuser=$SIGNEDINUSER -f main.bicep -o json)
AKSCLUSTER=$(echo $DEP | jq -r '.properties.outputs.aksClusterName.value')

az aks get-credentials --resource-group $RGNAME --name $AKSCLUSTER --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
echo "Kubernetes cluster is ready to use."
kubectl get nodes

# * configure TLS config file
# Set the email address you want to replace
old_email="user@example.com"
new_email="kubeflow@ziyixi.science"

# Update the email address on line 21
sed -i.bak "s/email: $old_email/email: $new_email/" kubeflow-aks/tls-manifest/manifests/common/dex/base/config-map.yaml

# Add the HASHED_PASSWORD environment variable on line 22
sed -i.bak "s/\(\s*hash:\s*\).*$/\1$HASHED_PASSWORD/" kubeflow-aks/tls-manifest/manifests/common/dex/base/config-map.yaml

# Remove the backup file created by the 'sed' command
rm kubeflow-aks/tls-manifest/manifests/common/dex/base/config-map.yaml.bak
cp -r tls-manifest/manifests/ manifests/

echo "config has been updated for TLS"

# * Install Kubeflow
echo "Installing Kubeflow..."
cd manifests/
while ! kustomize build example | awk '!/well-defined/' | kubectl apply -f -; do
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
kubectl rollout restart deployment dex -n auth

IP=$(kubectl -n istio-system get service istio-ingressgateway --output jsonpath={.status.loadBalancer.ingress[0].ip})
echo "Kubeflow is deployed at http://$IP/"
cd ..
sed -i '' "s/20.237.5.253/$IP/" tls-manifest/certificate.yaml

echo "Kubeflow is ready to use."

# * Wait for all required pods to be in the "Running" state
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

# * forward the kubeflow port
echo "Forwarding the Kubeflow port..."
kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80
echo "Enjoy Kubeflow port forwarding!"
