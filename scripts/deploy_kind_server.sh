#!/bin/bash

# List of required commands
commands=("kind" "kubectl" "kustomize" "python" "sed" "awk")

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

# Function to generate password hash
generate_password_hash() {
    # Check if Passlib is installed
    python -c "import passlib; import bcrypt" &>/dev/null

    if [ $? -eq 0 ]; then
        local python_cmd=$(cat <<EOF
import getpass
from passlib.hash import bcrypt

password = getpass.getpass()
hashed_password = bcrypt.using(rounds=12, ident="2y").hash(password)
print(hashed_password)
EOF
        )

        # Store the hashed password in the HASHED_PASSWORD environment variable
        export HASHED_PASSWORD=$(echo "$python_cmd" | python)
        # Escape special characters in the hashed password and remove square brackets
        HASHED_PASSWORD=$(echo "$HASHED_PASSWORD" | sed 's/[\$\[\]]/\\&/g')
        echo "Hashed password stored in the HASHED_PASSWORD environment variable as $HASHED_PASSWORD."
    else
        echo "Passlib or bcrypt is not installed. Please install it using 'pip install passlib bcrypt' and try again."
        exit 1
    fi
}

# Function to configure the Kubernetes cluster
configure_kubernetes_cluster() {
    echo "Configuring the Kubernetes cluster..."
    cp -r kubeflow-aks kubeflow-aks-runtime
    
    kind create cluster --config scripts/config/kind_config.yaml --wait 2m
    kubectl config use-context kind-kubecluster
    kubectl cluster-info
    kubectl get nodes
}

# Function to configure TLS config file
configure_tls_config_file() {
    cd kubeflow-aks-runtime
    # Set the email address you want to replace
    local old_email="user@example.com"
    local new_email="kubeflow@ziyixi.science"

    # Update the email address on line 21
    sed -i.bak "s/email: $old_email/email: $new_email/" tls-manifest/manifests/common/dex/base/config-map.yaml

    # Add the HASHED_PASSWORD environment variable on line 22
    local hashed_password_escaped=$(echo "$HASHED_PASSWORD" | sed 's/\$/\\$/g')
    sed -i.bak "s#\(\s*hash:\s*\).*\$#\1 \"$hashed_password_escaped\"#" tls-manifest/manifests/common/dex/base/config-map.yaml

    # Remove the backup file created by the 'sed' command
    rm tls-manifest/manifests/common/dex/base/config-map.yaml.bak

    echo "config has been updated for TLS"
    cd ..
}

# Function to install Kubeflow
install_kubeflow() {
    cd kubeflow-aks-runtime
    echo "Installing Kubeflow..."
    cd manifests/
    git checkout v1.6-branch
    cd ..
    cp -r tls-manifest/manifests/ manifests/
    cd manifests
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

    local ip=127.0.0.1
    echo "Kubeflow is deployed at http://$ip/"
    cd ..
    sed -i '' "s/20.237.5.253/$ip/" tls-manifest/certificate.yaml
    kubectl apply -f  tls-manifest/certificate.yaml 

    echo "Kubeflow is ready to use."
    cd ..
}


# Function to remove the kubeflow-aks-runtime folder
remove_kubeflow_aks_runtime() {
    rm -rf kubeflow-aks-runtime
    kind delete cluster --name kubecluster
}

# Main script execution
cd ..
check_commands_exist "${commands[@]}"
generate_password_hash
configure_kubernetes_cluster
configure_tls_config_file
install_kubeflow
# remove_kubeflow_aks_runtime