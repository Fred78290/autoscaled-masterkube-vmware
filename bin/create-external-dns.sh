#!/bin/bash
CURDIR=$(dirname $0)

pushd $CURDIR/../

export ETC_DIR=${TARGET_DEPLOY_LOCATION}/external-dns
export KUBERNETES_TEMPLATE=./templates/external-dns

mkdir -p $ETC_DIR

sed -e "s/__DOMAIN_NAME__/$DOMAIN_NAME/g" \
    -e "s/__GODADDY_API_KEY__/$GODADDY_API_KEY/g" \
    -e "s/__GODADDY_API_SECRET__/$GODADDY_API_SECRET/g" \
    -e "s/__NODEGROUP_NAME__/$NODEGROUP_NAME/g" \
    $KUBERNETES_TEMPLATE/deploy.yaml > $ETC_DIR/deploy.yaml

kubectl apply -f $ETC_DIR/deploy.yaml --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
