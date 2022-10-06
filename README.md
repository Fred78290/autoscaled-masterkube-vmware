[![Licence](https://img.shields.io/badge/License-GPL_v2-blue.svg)](https://github.com/Fred78290/autoscaled-masterkube-vmware/blob/master/LICENSE)

# Introduction

This directory contains everthing to create a single autoscaled cluster or HA cluster with worker node on vSphere infrastructure.

## Prerequistes

Ensure that you have sudo right

You must also install

|Linux|MacOS|
| --- | --- |
|kubectl|kubectl|
|govc|govc|
|jq|jq|
||gnu-getopt|
||gsed|

## Create the masterkube

First step is to fill a file named **govc.defs** in the bin directory with the values needed by govc tool

```
export GOVC_DATACENTER=
export GOVC_DATASTORE=
export GOVC_FOLDER=
export GOVC_FOLDER=
export GOVC_HOST=
export GOVC_INSECURE="1"
export GOVC_NETWORK=
export GOVC_USERNAME=
export GOVC_PASSWORD=
export GOVC_RESOURCE_POOL=
export GOVC_RESOURCE_POOL=
export GOVC_URL=
export GOVC_VIM_VERSION="6.0"
```

The simply way to create the masterkube is to run [create-masterkube.sh](create-masterkube.sh)

Some needed file are located in:

| Name | Description |
| --- | --- |
| `bin` | Essentials scripts to build the master kubernetes node  |
| `etc/ssl`  | Your CERT for https. Autosigned will be generated if empty  |
| `template`  | Templates files to deploy pod & service |

The first thing done by this script is to create a VM Template Ubuntu-20.04 image containing kubernetes binaries and a container runtime of you choice (docker/containerd/cri-o) with cni plugin (calico/flannel/weave/...). The VM template will be named by default focal-kubernetes-cni-(cni plugin)-(kuberneres version)-(container runtime)-(architecture)

as example: focal-kubernetes-cni-flannel-v1.23.1-containerd-amd64

Next step will be to launch a cloned VM and create a master node. It will also deploy a dashboard at the URL https://masterkube-vmware-dashboard.@your-domain@/

To connect to the dashboard, copy paste the token from file [cluster/vmware-ca-k8s/dashboard-token](./cluster/vmware-ca-k8s/dashboard-token)

Next step is to deploy a replicaset helloworld. This replicaset use hostnetwork:true to enforce one pod per node.

During the process the script will create many files located in

| Name | Description |
| --- | --- |
| `cluster/vmware-ca-k8s` | Essentials file to connect to kubernetes with kubeadm join  |
| `config/vmware-ca-k8s`  | Configuration file generated during the build process  |

**The cluster kubernetes will use metallb as load balancer for services declared LoadBalancer.**

## Command line arguments

| Parameter | Description | Default |
| --- | --- |--- |
| `-h\|--help` | Help  | |
| `-v\|--verbose` | Verbose mode  | |
| `-x\|--trace` | Trace execution  | |
| `-r\|--resume` | Allow to resume interrupted creation of cluster kubernetes  | |
| `--govc-defs` | Override the GOVC definitions  | bin/govc.defs |
| `--create-image-only`| Create image only and exit ||
| **Flag to design the kubernetes cluster** |
| `-c\|--ha-cluster` | Allow to create an HA cluster with 3 control planes | NO |
| `--worker-nodes` | Specify the number of worker node created in the cluster. | 3 |
| `--container-runtime` | Specify which OCI runtime to use. [**docker**\|**containerd**\|**cri-o**]| containerd |
| `--max-pods` | Specify the max pods per created VM. | 110 |
| `-d\|--default-machine` | Override machine type used for auto scaling | medium |
| `-k\|--ssh-private-key`  | Alternate ssh key file |~/.ssh/id_rsa|
| `-t\|--transport`  | Override the transport to be used between autoscaler and vmware-autoscaler [**tcp**\|**linux**] |linux|
| `--node-group`  | Override the node group name |vmware-ca-k8s|
| `--cni-plugin`  | Override CNI plugin [**calico**\|**flannel**\|**weave**\|**romana**]|flannel|
| `-n\|--cni-version`  | Override CNI plugin version |v1.1.1|
| `-k\|--kubernetes-version`  |Which version of kubernetes to use |latest|
| **Flags in ha mode only** |
| `-e\|--create-external-etcd` | Allow to create and use an external HA etcd cluster  | NO |
| `-u\|--use-keepalived` | Allow to use keepalived as load balancer else NGINX is used | NGINX |
| **Flags to set the template vm** |
| `--target-image` | The VM name created for cloning with kubernetes | focal-kubernetes |
| `--seed-image` | The VM name used to created the targer image | focal-server-cloudimg-seed |
| `--seed-user` | The cloud-init user name | ubuntu |
| `-p\|--password`  |Define the kubernetes user password |randomized|
| **Flags to set the template vm** |
| `--public-address` | The public address to expose kubernetes endpoint [**DHCP**\|**1.2.3.4**] | DHCP |
| `--no-dhcp-autoscaled-node` | Autoscaled node don't use DHCP | DHCP |
| `--vm-private-network` | Override the name of the private network in vsphere | 'Private Network' |
| `--vm-public-network` | Override the name of the public network in vsphere | 'Public Network' |
| `--net-address` | Override the IP of the kubernetes control plane node | 192.168.1.20 |
| `--net-gateway` | The public IP gateway | 10.0.0.1 |
| `--net-dns` | The public IP dns | 10.0.0.1 |
| `--net-domain` | The public domain name | example.com |
| `--metallb-ip-range` | Override the metalb ip range | 10.0.0.100-10.0.0.127 |
| **Flags for autoscaler** |
| `--max-nodes-total` | Maximum number of nodes in all node groups. Cluster autoscaler will not grow the cluster beyond this number. | 9 |
| `--cores-total` | Minimum and maximum number of cores in cluster, in the format < min >:< max >. Cluster autoscaler will not scale the cluster beyond these numbers. | 0:16 |
| `--memory-total` | Minimum and maximum number of gigabytes of memory in cluster, in the format < min >:< max >. Cluster autoscaler will not scale the cluster beyond these numbers. | 0:48 |
| `--max-autoprovisioned-node-group-count` | The maximum number of autoprovisioned groups in the cluster | 1 |
| `--scale-down-enabled` | Should CA scale down the cluster | true |
| `--scale-down-delay-after-add` | How long after scale up that scale down evaluation resumes | 1 minutes |
| `--scale-down-delay-after-delete` | How long after node deletion that scale down evaluation resumes, defaults to scan-interval | 1 minutes |
| `--scale-down-delay-after-failure` | How long after scale down failure that scale down evaluation resumes | 1 minutes |
| `--scale-down-unneeded-time` | How long a node should be unneeded before it is eligible for scale down | 1 minutes |
| `--scale-down-unready-time` | How long an unready node should be unneeded before it is eligible for scale down | 1 minutes |
| `--unremovable-node-recheck-timeout` | The timeout before we check again a node that couldn't be removed before | 1 minutes |

```bash
create-masterkube \
    --verbose \
    --ha-cluster \
    --nodegroup=<My Group Name> \
    --target-image=<My VM template Name> \
    --seed-image=<My custom VM Template> \
    --seed-user=<My custom user> \
    --vm-private-network=<My private network> \
    --vm-public-network=<My public network> \
    --net-address="10.0.4.200" \
    --net-gateway="10.0.4.1" \
    --net-dns="10.0.4.1" \
    --net-domain="acme.com"
```

## Raise autoscaling

To scale up or down the cluster, just play with `kubectl scale`

To scale fresh masterkube `kubectl scale --replicas=2 deploy/helloworld -n kube-public`

## Delete master kube and worker nodes

To delete the master kube and associated worker nodes, just run the command [delete-masterkube.sh](./bin/delete-masterkube.sh).
If the create process fail for any reason, you can use flag **--force**