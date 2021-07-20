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

join-broker() {
  pushd /root
  [[ ! -d knitnet-operator ]] && git clone https://github.com/tkestack/knitnet-operator.git
  pushd knitnet-operator
  git pull
  sed -i "s|clusterID:.*|clusterID: ${CLUSTER_NAME}|g" config/samples/join_broker.yaml
  kubectl apply -f config/samples/join_broker.yaml
  popd
  popd
}

join-broker-with-subctl() {
  title "Join self to the broker"
  subctl join broker-info.subm --clusterid $CLUSTER_NAME --natt=false
}

#------------------------------- main ----------------------------#
CLUSTER_NAME=$1
deployer=$2

if [[ "$deployer" == "subctl" ]]; then
  join-broker-with-subctl
else
  join-broker
fi
