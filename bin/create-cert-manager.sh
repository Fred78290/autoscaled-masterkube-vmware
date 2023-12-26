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
    26)
        CERT_MANAGER_VERSION=v1.11.5
        GODADDY_WEBHOOK_VERSION=v1.26.1
        ;;
    27)
        CERT_MANAGER_VERSION=v1.12.7
        GODADDY_WEBHOOK_VERSION=v1.27.2
        ;;
    28)
        CERT_MANAGER_VERSION=v1.13.3
        GODADDY_WEBHOOK_VERSION=v1.28.4
        ;;
    29)
        CERT_MANAGER_VERSION=v1.13.3
        GODADDY_WEBHOOK_VERSION=v1.28.4
        ;;
esac

mkdir -p $ETC_DIR

kubectl create namespace $K8NAMESPACE --dry-run=client -o yaml \
	--kubeconfig=${TARGET_CLUSTER_LOCATION}/config | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

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
    kubectl create secret generic ca-key-pair -n $K8NAMESPACE --dry-run=client -o yaml \
        --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
        --from-file=tls.crt=${SSL_LOCATION}/ca.pem \
        --from-file=tls.key=${SSL_LOCATION}/ca.key | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

    deploy cluster-issuer-selfsigned
else
    if [ "${USE_ZEROSSL}" = "YES" ]; then
        kubectl create secret generic zero-ssl-eabsecret -n $K8NAMESPACE --dry-run=client -o yaml \
			--kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
			--from-literal secret="${ZEROSSL_EAB_HMAC_SECRET}" | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -
    fi

    if [ -n "${AWS_ROUTE53_PUBLIC_ZONE_ID}" ]; then
        echo_blue_bold "Register route53 issuer"
        kubectl create secret generic route53-credentials-secret -n $K8NAMESPACE --dry-run=client -o yaml \
			--kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
			--from-literal=secret=${AWS_ROUTE53_SECRETKEY} | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

        deploy cluster-issuer-route53
    elif [ -n ${GODADDY_API_KEY} ]; then
        echo_blue_bold "Register godaddy issuer"
        helm upgrade -i godaddy-webhook godaddy-webhook/godaddy-webhook \
	        --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
            --version ${GODADDY_WEBHOOK_VERSION} \
            --set groupName=${PUBLIC_DOMAIN_NAME} \
            --set dnsPolicy=ClusterFirst \
            --namespace cert-manager

        kubectl create secret generic godaddy-api-key-prod -n $K8NAMESPACE --dry-run=client -o yaml \
            --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
            --from-literal=key=${GODADDY_API_KEY} \
            --from-literal=secret=${GODADDY_API_SECRET} | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

        deploy cluster-issuer-godaddy
    fi
fi