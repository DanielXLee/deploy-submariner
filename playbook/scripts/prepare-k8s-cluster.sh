#!/usr/bin/env bash

msg() {
  printf '%b\n' "$1"
}

success() {
  msg "\33[32m[✔] ${1}\33[0m"
}

error() {
  msg "\33[31m[✘] ${1}\33[0m"
}

title() {
  msg "\33[34m# ${1}\33[0m"
}

usage () {
  local script="${0##*/}"
  while read -r ; do echo "${REPLY}" ; done <<-EOF
    Usage: ${script} [CLUSTER_NAME] [POD_CIDR] [SRVIECE_CIDR] [PUBLIC_IP]
    Create k8s cluster with kubeadm
    Examples:
      1. Create a cluster-a:
        ${script} cluster-a 10.44.0.0 10.45.0.0 <cluster-a-public-ip> 
      2. Create a cluster-b:
        ${script} cluster-b 10.144.0.0 10.145.0.0 <cluster-b-public-ip>
      3. Create a cluster-c:
        ${script} cluster-c 10.244.0.0 10.245.0.0 <cluster-c-public-ip>
EOF
}

install-required-pkgs() {
  DOCKER=$(which docker 2>/dev/null)
  GO=$(which go 2>/dev/null)
  if [[ "X$DOCKER" == "X" || "X$GO" == "X" ]]; then
    title "Installing docker socat golang-go ..."
    apt update && apt install docker.io conntrack socat golang-go -y
  fi

  KUBERADM=$(which kubeadm 2>/dev/null)
  KUBELET=$(which kubelet 2>/dev/null)
  KUBECTL=$(which kubectl 2>/dev/null)
  if [[ "X$KUBERADM" == "X" || "X$KUBELET" == "X" || "X$KUBECTL" == "X" ]]; then
    title "Installing kubeadm, kubelet, kubectl with version: ${K8S_VERSION}"
    curl -L --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/{kubeadm,kubelet,kubectl}
    chmod +x {kubeadm,kubelet,kubectl}
    mv kubeadm kubelet kubectl /usr/bin/
  fi

  YQ=$(which yq 2>/dev/null)
  if [[ "X$YQ" == "X" ]]; then
    title "Installing yq"
    BINARY=yq_linux_amd64
    wget https://github.com/mikefarah/yq/releases/download/v4.8.0/${BINARY} -O /usr/bin/yq &&  chmod +x /usr/bin/yq
  fi

  title "Installing cni plugin"
  mkdir -p /opt/cni/bin
  if [[ ! -f cni-plugins-linux-amd64-${CNI_VERSION}.tgz ]]; then
    curl -L -o cni-plugins-linux-amd64-${CNI_VERSION}.tgz "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
  fi
  tar -xz -C /opt/cni/bin -f cni-plugins-linux-amd64-${CNI_VERSION}.tgz



  SUBCTL=$(which subctl 2>/dev/null)
  if [[ "X$SUBCTL" == "X" ]]; then
    title "Installing subctl command"
    curl -Ls https://get.submariner.io | bash
    mv ~/.local/bin/subctl /usr/bin/
  fi
}

prepare-pull-images() {
  add-docker-proxy
  docker pull k8s.gcr.io/kube-proxy:v1.19.7
  docker pull k8s.gcr.io/kube-apiserver:v1.19.7
  docker pull k8s.gcr.io/kube-scheduler:v1.19.7
  docker pull k8s.gcr.io/kube-controller-manager:v1.19.7
  docker pull k8s.gcr.io/etcd:3.4.13-0
  docker pull k8s.gcr.io/coredns:1.7.0
  docker pull k8s.gcr.io/pause:3.2
  remove-docker-proxy
}

init-kubeadm-cluster() {
  title "Reset kubeadm cluster"
  kubeadm reset -f

  title "Init kubeadm cluster"
  unset-proxy
  private_addr=$(ifconfig eth0 | awk '/inet /{print $2}')
  public_addr=$PUBLIC_IP
  kubeadm init --apiserver-advertise-address=$private_addr \
               --apiserver-cert-extra-sans=localhost,127.0.0.1,$private_addr,$public_addr \
               --pod-network-cidr=${POD_CIDR}/16  \
               --service-cidr=${SERVICE_CIDR}/16 \
               --kubernetes-version ${K8S_VERSION}
  [[ ! -d $HOME/.kube ]] && mkdir -p $HOME/.kube
  cp -f /etc/kubernetes/admin.conf $HOME/.kube/config

  title "Updating kube config"
  yq -i eval \
    '.clusters[].cluster.server |= sub("'$private_addr'", "'$public_addr'") | .contexts[].name = "'$CLUSTER_NAME'" | .current-context = "'$CLUSTER_NAME'"' \
    $HOME/.kube/config
  msg "Waiting for cluster ready"
  sleep 60
}

setup-docker() {
  title "Setup docker cgroup driver"
  sed -i 's,ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock,ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock --exec-opt native.cgroupdriver=systemd,' /lib/systemd/system/docker.service

  title "Restarting docker"
  systemctl daemon-reload
  systemctl restart docker
}

add-docker-proxy() {
  title "Setup docker proxy"
  if [[ "X$PROXY_SERVER" != "X" ]]; then
    DOCKER_SERVICE_D="/etc/systemd/system/docker.service.d"
    [[ ! -d ${DOCKER_SERVICE_D} ]] && mkdir -p ${DOCKER_SERVICE_D}
    cat >${DOCKER_SERVICE_D}/http-proxy.conf<<EOF
[Service]
Environment="HTTP_PROXY=http://${PROXY_SERVER}:${PROXY_PORT}/" "NO_PROXY=localhost,127.0.0.1,docker-registry.somecorporation.com"
EOF
  cat >${DOCKER_SERVICE_D}/https-proxy.conf<<EOF
[Service]
Environment="HTTPS_PROXY=http://${PROXY_SERVER}:${PROXY_PORT}/" "NO_PROXY=localhost,127.0.0.1,docker-registry.somecorporation.com"
EOF
  fi
  systemctl daemon-reload
  systemctl restart docker
}

remove-docker-proxy() {
  if [[ "X$PROXY_SERVER" != "X" ]]; then
    DOCKER_SERVICE_D="/etc/systemd/system/docker.service.d"
    if [[ ! -d ${DOCKER_SERVICE_D} ]]; then
      title "Remove docker proxy"
      rm -rf $DOCKER_SERVICE_D
      systemctl daemon-reload
      systemctl restart docker
    fi
  fi
}

setup-kubelet() {
  if ! systemctl status kubelet >/dev/null; then
    title "Set kubelet systemd service"
    RELEASE_VERSION="v0.4.0"
    curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service" | tee /etc/systemd/system/kubelet.service
    mkdir -p /etc/systemd/system/kubelet.service.d
    curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf" | tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

    title "Enable and start kubelet"
    systemctl enable --now kubelet
  fi
}

deploy-flannel() {
  title "Deploy kube flannel"
  [[ ! -f kube-flannel.yml ]] && curl -o kube-flannel.yml https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
  sed -i "s/10.244.0.0/${POD_CIDR}/g" kube-flannel.yml
  hostname=$(hostname)
  master_name=$(echo ${hostname,,})
  kubectl label node ${master_name} submariner.io/gateway=true
  kubectl taint nodes --all node-role.kubernetes.io/master-
  kubectl create -f kube-flannel.yml
  msg "Waiting for the kube flannel to boot up. This can take up to 2m0s"
  sleep 120
}

deploy-calico() {
  title "Deploy calico"
  [[ ! -f calico.yml ]] && curl -o calico.yml https://docs.projectcalico.org/manifests/calico.yaml
  hostname=$(hostname)
  master_name=$(echo ${hostname,,})
  kubectl label node ${master_name} submariner.io/gateway=true
  kubectl taint nodes --all node-role.kubernetes.io/master-
  kubectl create -f calico.yml
  msg "Waiting for the calico to boot up. This can take up to 1m0s"
  sleep 60
}

set-proxy() {
  if [[ "X$PROXY_SERVER" != "X" ]]; then
    title "Set http/https proxy"
    export http_proxy=http://${PROXY_SERVER}:${PROXY_PORT}
    export https_proxy=http://${PROXY_SERVER}:${PROXY_PORT}
  fi
}

unset-proxy() {
  if [[ "X$PROXY_SERVER" != "X" ]]; then
    title "Unset http/https proxy"
    unset http_proxy
    unset https_proxy
  fi
}
#------------------------------- main ----------------------------#
usage

#======================== Setup network proxy =======================#
PROXY_SERVER=${PROXY_SERVER:-}
PROXY_PORT=${PROXY_PORT:-3128}
NETWORK_PLUGIN=${NETWORK_PLUGIN:-flannel}
#====================================================================#

K8S_VERSION=${K8S_VERSION:-v1.19.7}
CNI_VERSION="v0.8.2"
CLUSTER_NAME=$1
POD_CIDR=$2
SERVICE_CIDR=$3
PUBLIC_IP=$4

[[ "X$CLUSTER_NAME" == "X" ]] && error "Miss cluster name" && exit 1
[[ "X$POD_CIDR" == "X" ]] && error "Miss pod-cidr" && exit 1
[[ "X$SERVICE_CIDR" == "X" ]] && error "Miss service-cidr" && exit 1
[[ "X$PUBLIC_IP" == "X" ]] && error "Miss public ip" && exit 1

# Download kubeadm, kubelet, kubectl, flannel
install-required-pkgs

# Pre-requiredpare load docker images
prepare-pull-images

setup-docker

setup-kubelet

init-kubeadm-cluster

if [[ "$NETWORK_PLUGIN" == "calico" ]];then
  deploy-calico
else
  deploy-flannel
fi
