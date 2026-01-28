#!/bin/bash

echo "Script runs here "$(pwd)

# Remove old ingress_ip.txt to prevent caching issues
rm -f ./ingress_ip.txt

# Needs to get executed from terraform !!!
INGRESS_NAMESPACE=ingress
INGRESS_SERVICE_NAME=traefik

# Script is started from Root-Folder, so metallb-values.yaml can be found
# That one is created by terraform 
helm repo add metallb https://metallb.github.io/metallb
helm upgrade --install --wait metallb metallb/metallb --version=0.13.12 --namespace metallb-system --create-namespace
# Now install the config 
helm upgrade --install metallb-config ./charts/metallb-config --namespace metallb-system -f metallb-values.yaml

helm repo add traefik https://traefik.github.io/charts
helm upgrade --install traefik traefik/traefik --version 38.0.2 --create-namespace --namespace ingress --skip-crds --reset-values 

# Waiting till we get an ip

while true; do
  IP=$(kubectl get svc "$INGRESS_SERVICE_NAME" -n "$INGRESS_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [[ -n "$IP" ]]; then
    echo "$IP"
    # it needs to be json format
    echo "{\"ingress_ip\":\"$IP\"}" > ingress_ip.txt
    break
  fi
  sleep 5
done


