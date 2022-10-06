#!/bin/bash
function deploy {
    echo "Create $ETC_DIR/$1.json"
    echo $(eval "cat <<EOF
    $(<$KUBERNETES_TEMPLATE/$1.json)
EOF") | jq . > $ETC_DIR/$1.json

    kubectl apply -f $ETC_DIR/$1.json --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
}

if [ -z "${PUBLIC_DOMAIN_NAME}" ] || [ -z ${GODADDY_API_KEY} ]; then
    echo "Don't install cert-manager, no public domain defined"
else
    echo "Install cert-manager"

    export K8NAMESPACE=cert-manager
    export ETC_DIR=${TARGET_DEPLOY_LOCATION}/cert-manager
    export KUBERNETES_TEMPLATE=./templates/cert-manager

    mkdir -p $ETC_DIR

    kubectl --kubeconfig=${TARGET_CLUSTER_LOCATION}/config create namespace $K8NAMESPACE

    helm repo add jetstack https://charts.jetstack.io
    helm repo update

    helm upgrade -i cert-manager jetstack/cert-manager --kubeconfig=${TARGET_CLUSTER_LOCATION}/config --namespace $K8NAMESPACE --version v1.9.1 --set installCRDs=true

    kubectl create secret generic godaddy-api-key-prod --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n cert-manager --from-literal=key=${GODADDY_API_KEY} --from-literal=secret=${GODADDY_API_SECRET}

    helm repo add godaddy-webhook https://fred78290.github.io/cert-manager-webhook-godaddy/
    helm repo update

    helm upgrade -i godaddy-webhook godaddy-webhook/godaddy-webhook \
        --set groupName=${PUBLIC_DOMAIN_NAME} \
        --set dnsPolicy=Default \
        --namespace cert-manager

    deploy cluster-issuer
fi