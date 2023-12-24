for KVERSION in v1.26.12 v1.27.9 v1.28.5 v1.29.0
do
	for DISTRO in kubeadm rke2 k3s
	do
		echo "Create image: ${DISTRO} - ${KVERSION}"
		./bin/create-masterkube.sh --k8s-distribution=${DISTRO} --kubernetes-version=${KVERSION} --verbose --create-image-only
	done
done