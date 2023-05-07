#!/bin/bash
mkdir -p cloudinit

if [ "$(uname -s)" == "Darwin" ]; then
    shopt -s expand_aliases

    alias base64=gbase64
    alias sed=gsed
    alias getopt=/usr/local/opt/gnu-getopt/bin/getopt
fi

cat <<EOF | tee cloudinit/user-data | gzip -c9 | base64 -w 0 > cloudinit/userdata.base64
#cloud-config
package_update: false
package_upgrade: false
runcmd:
  - echo 1 > /sys/block/sda/device/rescan
  - growpart /dev/sda 1
  - resize2fs /dev/sda1
  - touch /var/log/cloud-init-ok
  - echo '192.168.1.120 vmware-dev-k3s-masterkube vmware-dev-k3s-masterkube.aldunelabs.fr' >> /etc/hosts
EOF

cat > "cloudinit/network.yaml" <<EOF
#cloud-config
network:
    version: 2
    ethernets:
        eth0:
            dhcp4: true
EOF

cat <<EOF | tee cloudinit/vendor-data | gzip -c9 | base64 -w 0 > cloudinit/vendordata.base64
#cloud-config
timezone: Europe/Paris
ssh_authorized_keys:
    - $(cat $HOME/.ssh/id_rsa.pub)
users:
    - default
system_info:
    default_user:
        name: kubernetes
EOF

cat <<EOF | tee cloudinit/meta-data | gzip -c9 | base64 -w 0 > cloudinit/metadata.base64
{
    "local-hostname": "test",
    "instance-id": "$(uuidgen)"
}
EOF

#gzip -c9 < "meta-data" | base64 -w 0 > metadata.base64
#gzip -c9 < "user-data" | base64 -w 0 > userdata.base64
#gzip -c9 < "vendor-data" | base64 -w 0 > vendordata.base64

govc vm.clone -on=false -folder=/DC01/vm/HOME -c=2 -m=2048 -vm=jammy-kubernetes-cni-flannel-v1.27.1-containerd-amd64 test-cloud-init

govc vm.change -vm test-cloud-init \
    -e disk.enableUUID=1 \
    -e guestinfo.metadata="$(cat cloudinit/metadata.base64)" \
    -e guestinfo.metadata.encoding="gzip+base64" \
    -e guestinfo.userdata="$(cat cloudinit/userdata.base64)" \
    -e guestinfo.userdata.encoding="gzip+base64" \
    -e guestinfo.vendordata="$(cat cloudinit/vendordata.base64)" \
    -e guestinfo.vendordata.encoding="gzip+base64"
