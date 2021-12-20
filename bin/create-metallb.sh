#!/bin/bash
CURDIR=$(dirname $0)

pushd $CURDIR/../

export KUBERNETES_TEMPLATE=./templates/metallb
export ETC_DIR=./config/${NODEGROUP_NAME}/deployment/metallb

mkdir -p $ETC_DIR

# https://raw.githubusercontent.com/metallb/metallb/v0.11.0/manifests/namespace.yaml
# https://raw.githubusercontent.com/google/metallb/v0.11.0/manifests/metallb.yaml
sed "s/__METALLB_IP_RANGE__/$METALLB_IP_RANGE/g" $KUBERNETES_TEMPLATE/metallb.yaml > $ETC_DIR/metallb.yaml

kubectl --kubeconfig=./cluster/${NODEGROUP_NAME}/config apply -f $KUBERNETES_TEMPLATE/namespace.yaml
kubectl --kubeconfig=./cluster/${NODEGROUP_NAME}/config create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
kubectl --kubeconfig=./cluster/${NODEGROUP_NAME}/config apply -f $ETC_DIR/metallb.yaml
