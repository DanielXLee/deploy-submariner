#!/bin/bash
ANSIBLE=$(which ansible-playbook)
[[ "X$ANSIBLE" == "X" ]] && echo "Miss ansible, follow readme install ansible" && exit 1
DEBUG=""
region=$1
if [[ "X$region" == "X" ]]; then
  ansible-playbook -i inventory playbook/play.yml $DEBUG
else
  [[ ! -f inventory-$region ]] && echo "miss inventory-$region file" && exit 1
  ansible-playbook -i inventory-${region} playbook/play.yml $DEBUG
fi
