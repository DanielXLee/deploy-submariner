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

deploy-broker() {
  pushd /root
  [[ ! -d knitnet-operator ]] && git clone https://github.com/tkestack/knitnet-operator.git
  pushd knitnet-operator
  public_apiserver=$(kubectl config view  | grep server | cut -f 2- -d ":" | tr -d " ")
  sed -i "s|publicAPIServerURL:.*|publicAPIServerURL: ${public_apiserver}|g" config/samples/deploy_broker.yaml
  kubectl apply -f config/samples/deploy_broker.yaml
  popd
  popd
}

deploy-broker-with-subctl() {
  title "Deploy submariner broker"
  subctl deploy-broker 
}

#------------------------------- main ----------------------------#
deployer=$1

if [[ "$deployer" == "subctl" ]]; then
  deploy-broker-with-subctl
else
  deploy-broker
fi
sleep 30
