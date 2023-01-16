#/bin/bash
LAUNCH_CA=$1

CURDIR=$(dirname $0)

pushd $CURDIR/../

MASTER_IP=$(cat ${TARGET_CLUSTER_LOCATION}/manager-ip)
TOKEN=$(cat ${TARGET_CLUSTER_LOCATION}/token)
CACERT=$(cat ${TARGET_CLUSTER_LOCATION}/ca.cert)

export K8NAMESPACE=kube-system
export ETC_DIR=${TARGET_DEPLOY_LOCATION}/autoscaler
export KUBERNETES_TEMPLATE=./templates/autoscaler
export KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | cut -d . -f 2)
export CLUSTER_AUTOSCALER_VERSION=v1.22.1
export VSPHERE_AUTOSCALER_VERSION=v1.22.5
export AUTOSCALER_REGISTRY=$REGISTRY
export CLOUDPROVIDER_CONFIG=/etc/cluster/grpc-config.json
export USE_VANILLA_GRPC=--no-use-vanilla-grpc

if [ "${GRPC_PROVIDER}" = "externalgrpc" ]; then
    USE_VANILLA_GRPC=--use-vanilla-grpc
    AUTOSCALER_REGISTRY=k8s.gcr.io/autoscaling
    CLOUDPROVIDER_CONFIG=/etc/cluster/grpc-config.yaml
fi

case $KUBERNETES_MINOR_RELEASE in
    25)
        CLUSTER_AUTOSCALER_VERSION=v1.25.6
        VSPHERE_AUTOSCALER_VERSION=v1.25.6
        ;;
    26)
        CLUSTER_AUTOSCALER_VERSION=v1.26.1
        VSPHERE_AUTOSCALER_VERSION=v1.26.1
        ;;
    *)
        echo "Former version aren't supported by vmware autoscaler"
        exit 1
esac

mkdir -p $ETC_DIR

function deploy {
    echo "Create $ETC_DIR/$1.json"
echo $(eval "cat <<EOF
$(<$KUBERNETES_TEMPLATE/$1.json)
EOF") | jq . > $ETC_DIR/$1.json

kubectl apply -f $ETC_DIR/$1.json --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
}

deploy service-account-autoscaler
deploy service-account-vsphere
deploy cluster-role
deploy role
deploy cluster-role-binding
deploy role-binding

if [ "$LAUNCH_CA" == YES ]; then
    deploy deployment
elif [ "$LAUNCH_CA" == "DEBUG" ]; then
    deploy autoscaler
elif [ "$LAUNCH_CA" == "LOCAL" ]; then
    GOOS=$(go env GOOS)
    GOARCH=$(go env GOARCH)
    nohup ../out/$GOOS/$GOARCH/vsphere-autoscaler \
        --kubeconfig=$KUBECONFIG \
        --config=${TARGET_CONFIG_LOCATION}/kubernetes-vmware-autoscaler.json \
        --save=${TARGET_CONFIG_LOCATION}/vmware-autoscaler-state.json \
        --log-level=info 1>>${TARGET_CONFIG_LOCATION}/vmware-autoscaler.log 2>&1 &
    pid="$!"

    echo -n "$pid" > ${TARGET_CONFIG_LOCATION}/vmware-autoscaler.pid

    deploy autoscaler
else
    deploy deployment
fi

popd
