#!/bin/bash
CURDIR=$(dirname $0)
NODEGROUP_NAME="vmware-ca-k8s"
MASTERKUBE=${NODEGROUP_NAME}-masterkube
CONTROLNODES=3
WORKERNODES=3
FORCE=NO
GOVCDEFS=${CURDIR}/govc.defs

TEMP=$(getopt -o fg:p:r: --long aws-defs:,force,node-group:,profile:,region: -n "$0" -- "$@")

eval set -- "${TEMP}"

while true; do
    case "$1" in
        --aws-defs)
            GOVCDEFS=$2
            if [ ! -f ${GOVCDEFS} ]; then
                echo_red "AWS definitions: ${GOVCDEFS} not found"
                exit 1
            fi
            shift 2
            ;;
        -f|--force)
            FORCE=YES
            shift 1
            ;;
        -p|--profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -g|--node-group)
            NODEGROUP_NAME=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "$1 - Internal error!"
            exit 1
            ;;
    esac
done

# import govc hidden definitions
source ${GOVCDEFS}

pushd ${CURDIR}/../

echo "Delete masterkube ${MASTERKUBE} previous instance"

if [ -f ./cluster/${NODEGROUP_NAME}/buildenv ]; then
    source ./cluster/${NODEGROUP_NAME}/buildenv
fi

if [ "$(uname -s)" == "Linux" ]; then
    SED=sed
else
    SED=gsed
fi

if [ "$FORCE" = "YES" ]; then
    TOTALNODES=$((WORKERNODES + $CONTROLNODES))

    for NODEINDEX in $(seq 0 $TOTALNODES)
    do
        if [ $NODEINDEX = 0 ]; then
            MASTERKUBE_NODE="${MASTERKUBE}"
        elif [[ $NODEINDEX > $CONTROLNODES ]]; then
            NODEINDEX=$((NODEINDEX - $CONTROLNODES))
            MASTERKUBE_NODE="${NODEGROUP_NAME}-worker-0${NODEINDEX}"
        else
            MASTERKUBE_NODE="${NODEGROUP_NAME}-master-0${NODEINDEX}"
        fi

        if [ "$(govc vm.info ${MASTERKUBE_NODE} 2>&1)" ]; then
            echo "Delete VM: $MASTERKUBE_NODE"
            govc vm.power -persist-session=false -s $MASTERKUBE_NODE || echo "Already power off"
            govc vm.destroy $MASTERKUBE_NODE
        fi

        sudo $SED -i "/${MASTERKUBE_NODE}/d" /etc/hosts
    done
elif [ -f ./cluster/${NODEGROUP_NAME}/config ]; then
    for vm in $(kubectl get node -o json --kubeconfig ./cluster/${NODEGROUP_NAME}/config | jq '.items| .[] | .metadata.labels["kubernetes.io/hostname"]')
    do
        vm=$(echo -n $vm | tr -d '"')
        if [ ! -z "$(govc vm.info $vm 2>&1)" ]; then
            echo "Delete VM: $vm"
            govc vm.power -persist-session=false -s $vm
            govc vm.destroy $vm
        fi
        sudo $SED -i "/${vm}/d" /etc/hosts
    done

    if [ ! -z "$(govc vm.info $MASTERKUBE 2>&1)" ]; then
        echo "Delete VM: $MASTERKUBE"
        govc vm.power -persist-session=false -s $MASTERKUBE
        govc vm.destroy $MASTERKUBE
    fi
fi

./bin/kubeconfig-delete.sh $MASTERKUBE $NODEGROUP_NAME &> /dev/null

if [ -f config/${NODEGROUP_NAME}/vmware-autoscaler.pid ]; then
    kill $(cat config/${NODEGROUP_NAME}/vmware-autoscaler.pid)
fi

rm -rf ./cluster/${NODEGROUP_NAME}
rm -rf ./config/${NODEGROUP_NAME}

sudo $SED -i "/${MASTERKUBE}/d" /etc/hosts
sudo $SED -i "/masterkube-vmware/d" /etc/hosts

popd