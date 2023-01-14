#!/bin/bash
CURDIR=$(dirname $0)
NODEGROUP_NAME="vmware-ca-k8s"
MASTERKUBE=${NODEGROUP_NAME}-masterkube
CONTROLNODES=3
WORKERNODES=3
FORCE=NO

pushd ${CURDIR}/../

CONFIGURATION_LOCATION=${PWD}
GOVCDEFS=${PWD}/bin/govc.defs

if [ "$OSDISTRO" == "Darwin" ]; then
    shopt -s expand_aliases
    alias base64=gbase64
    alias sed=gsed
    alias getopt=/usr/local/opt/gnu-getopt/bin/getopt
fi

TEMP=$(getopt -o fg:p:r: --long configuration-location:,govc-defs:,force,node-group:,profile:,region: -n "$0" -- "$@")

eval set -- "${TEMP}"

while true; do
    case "$1" in
        --govc-defs)
            GOVCDEFS=$2
            if [ ! -f ${GOVCDEFS} ]; then
                echo_red "GOVC definitions: ${GOVCDEFS} not found"
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
        --configuration-location)
            CONFIGURATION_LOCATION=$2
            if [ ! -d ${CONFIGURATION_LOCATION} ]; then
                echo_red_bold "kubernetes output : ${CONFIGURATION_LOCATION} not found"
                exit 1
            fi
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo_red_bold "$1 - Internal error!"
            exit 1
            ;;
    esac
done

# import govc hidden definitions
source ${GOVCDEFS}

TARGET_CONFIG_LOCATION=${CONFIGURATION_LOCATION}/config/${NODEGROUP_NAME}/config
TARGET_DEPLOY_LOCATION=${CONFIGURATION_LOCATION}/config/${NODEGROUP_NAME}/deployment
TARGET_CLUSTER_LOCATION=${CONFIGURATION_LOCATION}/cluster/${NODEGROUP_NAME}

echo_blue_bold "Delete masterkube ${MASTERKUBE} previous instance"

if [ -f ${TARGET_CLUSTER_LOCATION}/buildenv ]; then
    source ${TARGET_CLUSTER_LOCATION}/buildenv
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
            echo_blue_bold "Delete VM: $MASTERKUBE_NODE"
            govc vm.power -persist-session=false -s $MASTERKUBE_NODE || echo_blue_bold "Already power off"
            govc vm.destroy $MASTERKUBE_NODE
        fi

        sudo sed -i "/${MASTERKUBE_NODE}/d" /etc/hosts
    done
elif [ -f ${TARGET_CLUSTER_LOCATION}/config ]; then
    for vm in $(kubectl get node -o json --kubeconfig ${TARGET_CLUSTER_LOCATION}/config | jq '.items| .[] | .metadata.labels["kubernetes.io/hostname"]')
    do
        vm=$(echo -n $vm | tr -d '"')
        if [ ! -z "$(govc vm.info $vm 2>&1)" ]; then
            echo_blue_bold "Delete VM: $vm"
            govc vm.power -persist-session=false -s $vm
            govc vm.destroy $vm
        fi
        sudo sed -i "/${vm}/d" /etc/hosts
    done

    if [ ! -z "$(govc vm.info $MASTERKUBE 2>&1)" ]; then
        echo_blue_bold "Delete VM: $MASTERKUBE"
        govc vm.power -persist-session=false -s $MASTERKUBE
        govc vm.destroy $MASTERKUBE
    fi
fi

./bin/kubeconfig-delete.sh $MASTERKUBE $NODEGROUP_NAME &> /dev/null

if [ -f ${TARGET_CONFIG_LOCATION}/vmware-autoscaler.pid ]; then
    kill ${TARGET_CONFIG_LOCATION}/vmware-autoscaler.pid
fi

rm -rf ${TARGET_CLUSTER_LOCATION}
rm -rf ${TARGET_CONFIG_LOCATION}
rm -rf ${TARGET_DEPLOY_LOCATION}

sudo sed -i "/${MASTERKUBE}/d" /etc/hosts
sudo sed -i "/masterkube-vmware/d" /etc/hosts

popd