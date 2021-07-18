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

prepare-pull-images() {
  add-docker-proxy
  docker pull quay.io/danielxlee/knitnet-operator:latest
  docker pull quay.io/submariner/submariner-operator:0.9.1
  docker pull quay.io/submariner/lighthouse-coredns:0.9.1
  docker pull quay.io/submariner/lighthouse-agent:0.9.1
  docker pull quay.io/submariner/submariner-globalnet:0.9.1
  docker pull quay.io/submariner/submariner-route-agent:0.9.1
  docker pull quay.io/submariner/submariner-gateway:0.9.1
  remove-docker-proxy
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

deploy-knitnet() {
  title "Deploy knitnet operator"
  pushd /root
  [[ ! -d knitnet-operator ]] && git clone https://github.com/tkestack/knitnet-operator.git
  pushd knitnet-operator
  title "Prepare go mod"
  set-proxy
  make manifests
  make kustomize
  unset-proxy
  title "Install knitnet operator"
  make deploy
  popd
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
PROXY_SERVER=${PROXY_SERVER:-}
PROXY_PORT=${PROXY_PORT:-3128}
#====================================================================#

# Prepare load docker images
prepare-pull-images

deploy-knitnet


