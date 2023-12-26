#!/bin/bash
CURDIR=$(dirname $0)

pushd $CURDIR/../ &>/dev/null

export KUBERNETES_TEMPLATE=./templates/metallb
export ETC_DIR=${TARGET_DEPLOY_LOCATION}/metallb

mkdir -p $ETC_DIR

# https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml
sed "s/__METALLB_IP_RANGE__/$METALLB_IP_RANGE/g" $KUBERNETES_TEMPLATE/metallb.yaml > $ETC_DIR/metallb.yaml
sed "s/__METALLB_IP_RANGE__/$METALLB_IP_RANGE/g" $KUBERNETES_TEMPLATE/config.yaml > $ETC_DIR/config.yaml

kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f $ETC_DIR/metallb.yaml
kubectl create secret generic -n metallb-system memberlist --dry-run=client -o yaml \
	--kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
	--from-literal=secretkey="$(openssl rand -base64 128)" | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

echo -n "Wait MetalLB ready"
while [ -z "$(kubectl --kubeconfig=${TARGET_CLUSTER_LOCATION}/config get po -n metallb-system 2>/dev/null | grep 'controller')" ];
do
    sleep 1
    echo -n "."
done

echo

kubectl --kubeconfig=${TARGET_CLUSTER_LOCATION}/config wait deployment controller -n metallb-system --for=condition=Available=True --timeout=120s

kubectl --kubeconfig=${TARGET_CLUSTER_LOCATION}/config apply -f $ETC_DIR/config.yaml
echo "Done"
