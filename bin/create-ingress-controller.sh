#!/bin/bash

CURDIR=$(dirname $0)

pushd $CURDIR/../ &>/dev/null

export K8NAMESPACE=ingress-nginx
export ETC_DIR=${TARGET_DEPLOY_LOCATION}/ingress
export KUBERNETES_TEMPLATE=./templates/ingress

mkdir -p $ETC_DIR

sed "s/__K8NAMESPACE__/$K8NAMESPACE/g" $KUBERNETES_TEMPLATE/deploy.yaml > $ETC_DIR/deploy.yaml

kubectl apply -f $ETC_DIR/deploy.yaml --kubeconfig=${TARGET_CLUSTER_LOCATION}/config

echo -n "Wait for ingress controller availability"

while [ -z "$(kubectl --kubeconfig=${TARGET_CLUSTER_LOCATION}/config get po -n $K8NAMESPACE 2>/dev/null | grep 'ingress-nginx-controller')" ];
do
    sleep 1
    echo -n "."
done

echo

kubectl wait --kubeconfig=${TARGET_CLUSTER_LOCATION}/config --namespace $K8NAMESPACE --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=240s
