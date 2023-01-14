#!/bin/bash
CURDIR=$(dirname $0)

source $CURDIR/common.sh

function deploy {
    echo "Create $ETC_DIR/$1.json"

    CONFIG=$(eval "cat <<EOF
$(<$KUBERNETES_TEMPLATE/$1.json)
EOF")

    if [ -z "${PUBLIC_DOMAIN_NAME}" ]; then
        echo $CONFIG | jq . > $ETC_DIR/cluster-issuer.json
    elif [ "${USE_ZEROSSL}" = "YES" ]; then
        echo $CONFIG | jq \
            --arg SERVER "https://acme.zerossl.com/v2/DV90" \
            --arg ZEROSSL_EAB_KID $ZEROSSL_EAB_KID \
            '.spec.acme.server = $SERVER | .spec.acme.externalAccountBinding = {"keyID": $ZEROSSL_EAB_KID, "keyAlgorithm": "HS256", "keySecretRef": { "name": "zero-ssl-eabsecret", "key": "secret"}}' > $ETC_DIR/cluster-issuer.json
    else
        echo $CONFIG | jq \
            --arg SERVER "https://acme-v02.api.letsencrypt.org/directory" \
            --arg CERT_EMAIL ${CERT_EMAIL} \
            '.spec.acme.server = $SERVER | .spec.acme.email = $CERT_EMAIL' > $ETC_DIR/cluster-issuer.json
    fi

    kubectl apply -f $ETC_DIR/cluster-issuer.json --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
}

echo_blue_bold "Install cert-manager"

export K8NAMESPACE=cert-manager
export ETC_DIR=${TARGET_DEPLOY_LOCATION}/cert-manager
export KUBERNETES_TEMPLATE=./templates/cert-manager

KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | tr '.' ' ' | awk '{ print $2 }')

case $KUBERNETES_MINOR_RELEASE in
    24)
        CERT_MANAGER_VERSION=v1.8.0
        GODADDY_WEBHOOK_VERSION=v1.24.6
        ;;
    25)
        CERT_MANAGER_VERSION=v1.9.1
        GODADDY_WEBHOOK_VERSION=v1.25.5
        ;;
    26)
        CERT_MANAGER_VERSION=v1.10.1
        GODADDY_WEBHOOK_VERSION=v1.26.0
        ;;
esac

mkdir -p $ETC_DIR

kubectl --kubeconfig=${TARGET_CLUSTER_LOCATION}/config create namespace $K8NAMESPACE

helm repo add jetstack https://charts.jetstack.io
helm repo add godaddy-webhook https://fred78290.github.io/cert-manager-webhook-godaddy/
helm repo update

helm upgrade -i $K8NAMESPACE jetstack/cert-manager \
        --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
        --namespace $K8NAMESPACE \
        --version ${CERT_MANAGER_VERSION} \
        --set installCRDs=true

if [ -z "${PUBLIC_DOMAIN_NAME}" ]; then
    echo_blue_bold "Register CA self signed issuer"
    kubectl create secret generic ca-key-pair \
        --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
        --namespace $K8NAMESPACE \
        --from-file=tls.crt=${SSL_LOCATION}/ca.pem \
        --from-file=tls.key=${SSL_LOCATION}/ca.key

    deploy cluster-issuer-selfsigned
else
    if [ "${USE_ZEROSSL}" = "YES" ]; then
        kubectl create secret generic zero-ssl-eabsecret -n $K8NAMESPACE --from-literal secret="${ZEROSSL_EAB_HMAC_SECRET}"
    fi

    if [ ! -z "${AWS_ROUTE53_PUBLIC_ZONE_ID}" ]; then
        echo_blue_bold "Register route53 issuer"
        kubectl create secret generic route53-credentials-secret --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n $K8NAMESPACE --from-literal=secret=${AWS_ROUTE53_SECRETKEY}

        deploy cluster-issuer-route53
    elif [ ! -z ${GODADDY_API_KEY} ]; then
        echo_blue_bold "Register godaddy issuer"
        helm upgrade -i godaddy-webhook godaddy-webhook/godaddy-webhook \
            --version ${GODADDY_WEBHOOK_VERSION} \
            --set groupName=${PUBLIC_DOMAIN_NAME} \
            --set dnsPolicy=ClusterFirst \
            --namespace cert-manager

        kubectl create secret generic godaddy-api-key-prod \
            --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
            -n $K8NAMESPACE \
            --from-literal=key=${GODADDY_API_KEY} \
            --from-literal=secret=${GODADDY_API_SECRET}

        deploy cluster-issuer-godaddy
    fi
fi