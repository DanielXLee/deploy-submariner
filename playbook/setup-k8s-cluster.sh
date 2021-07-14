#!/bin/bash

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

install-pkgs() {
  DOCKER=$(which docker 2>/dev/null)
  if [[ "X$DOCKER" == "X" ]]; then
    title "Installing docker socat golang-go packages"
    apt update && apt install docker.io conntrack socat golang-go -y
  fi

  KUBERADM=$(which kubeadm 2>/dev/null)
  if [[ "X$KUBERADM" == "X" ]]; then
    title "Installing kubeadm"
    curl -o /usr/bin/kubeadm https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubeadm && chmod +x /usr/bin/kubeadm
  fi

  KUBELET=$(which kubelet 2>/dev/null)
  if [[ "X$KUBELET" == "X" ]]; then
    title "Installing kubelet"
    curl -o /usr/bin/kubelet https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubelet && chmod +x /usr/bin/kubelet
  fi

  KUBECTL=$(which kubectl 2>/dev/null)
  if [[ "X$KUBECTL" == "X" ]]; then
    title "Installing kubectl"
    curl -o /usr/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubectl && chmod +x /usr/bin/kubectl
  fi

  YQ=$(which yq 2>/dev/null)
  if [[ "X$YQ" == "X" ]]; then
    title "Installing yq"
    BINARY=yq_linux_amd64
    wget https://github.com/mikefarah/yq/releases/download/v4.8.0/${BINARY} -O /usr/bin/yq &&  chmod +x /usr/bin/yq
  fi

  if [[ ! -d /opt/cni ]]; then
    title "Installing cni plugin"
    mkdir -p /opt/cni/bin
    wget -c  "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" -O - | tar -C /opt/cni/bin -xz
  fi

  SUBCTL=$(which subctl 2>/dev/null)
  if [[ "X$SUBCTL" == "X" ]]; then
    title "Installing subctl command"
    curl -Ls https://get.submariner.io | bash
    echo "export PATH=\$PATH:~/.local/bin" >> ~/.bashrc
    source ~/.bashrc
  fi
}

prepare-pull-images() {
  add-docker-proxy
  docker pull quay.io/danielxlee/knitnet-operator:latest
  docker pull quay.io/submariner/submariner-operator:0.9.1
  docker pull quay.io/submariner/lighthouse-coredns:0.9.1
  docker pull quay.io/submariner/lighthouse-agent:0.9.1
  docker pull quay.io/submariner/submariner-globalnet:0.9.1
  docker pull quay.io/submariner/submariner-route-agent:0.9.1
  docker pull quay.io/submariner/submariner-gateway:0.9.1
  docker pull quay.io/coreos/flannel:v0.14.0
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

deploy-knitnet() {
  pushd /root
  [[ ! -d knitnet-operator ]] && git clone https://github.com/tkestack/knitnet-operator.git
  pushd knitnet-operator
    set-proxy
    make manifests
    make kustomize
    unset-proxy
    make deploy
  popd
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

#======================== Setup network proxy =======================#
PROXY_SERVER=
PROXY_PORT=8123
#====================================================================#


K8S_VERSION="v1.19.7"
CNI_VERSION="v0.8.2"
CLUSTER_NAME=$1
POD_CIDR=$2
SERVICE_CIDR=$3
PUBLIC_IP=$4

msg "Example usage: ./setup-k8s-cluster.sh cluster-a 10.44.0.0 10.45.0.0 <cluster-a-public-ip>"
msg "Example usage: ./setup-k8s-cluster.sh cluster-b 10.144.0.0 10.145.0.0 <cluster-b-public-ip>"
msg "Example usage: ./setup-k8s-cluster.sh cluster-c 10.244.0.0 10.245.0.0 <cluster-c-public-ip>"

[[ "X$CLUSTER_NAME" == "X" ]] && error "Miss cluster name" && exit 1
[[ "X$POD_CIDR" == "X" ]] && error "Miss pod-cidr" && exit 1
[[ "X$SERVICE_CIDR" == "X" ]] && error "Miss service-cidr" && exit 1
[[ "X$PUBLIC_IP" == "X" ]] && error "Miss public ip" && exit 1

# Prepare load docker images
prepare-pull-images

# Download kubeadm, kubelet, kubectl, flannel
install-pkgs

setup-docker

setup-kubelet

init-kubeadm-cluster

deploy-flannel

remove-docker-proxy

deploy-knitnet


