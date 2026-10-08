#!/bin/bash

pushd ..

# Gateway
kubectl create namespace ingress-gw --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f gateways/gw-parameters.yaml
kubectl apply -f gateways/gw.yaml

kubectl create namespace httpbin --dry-run=client -o yaml | kubectl apply -f -

# Label the default namespace, so the gateway will accept the HTTPRoute from that namespace.
printf "\nLabel default namespace ...\n"
kubectl label namespaces default --overwrite shared-gateway-access="true"

# Deploy the HTTPBin application (the backend that echoes the transformed request)
printf "\nDeploy HTTPBin application ...\n"
kubectl apply -f apis/httpbin.yaml

# Reference Grants
printf "\nDeploy Reference Grants ...\n"
kubectl apply -f referencegrants/httpbin-ns/default-ns-httproute-service-rg.yaml

# HTTPRoutes: api.example.com (httpbin) and keycloak.example.com (Keycloak)
printf "\nDeploy HTTPRoutes ...\n"
kubectl apply -f routes/api-example-com-httproute.yaml
kubectl apply -f routes/keycloak-example-com-httproute.yaml

printf "\nWait for Gateway and HTTPBin readiness ...\n"
kubectl -n ingress-gw rollout status deploy/gw --timeout=300s
kubectl -n httpbin rollout status deploy/httpbin --timeout=300s

# Keycloak realm 'kgateway-demo': groups TOTO/TATA/TITI, user1, client 'kgateway-client' with a 'groups' claim.
printf "\nProvision Keycloak realm 'kgateway-demo' ...\n"
# Stop here if it fails: ExtAuth rejects the AuthConfig below if the realm's JWKS endpoint does not exist yet.
./install/keycloak-kgateway-demo-realm.sh || { popd; exit 1; }

# AuthConfig (access token validation + groups claim -> dynamic metadata)
printf "\nDeploy AuthConfig ...\n"
kubectl apply -f policies/authconfig/oauth-atv-authconfig.yaml

# EnterpriseKgatewayTrafficPolicy (ExtAuth + Inja transformation that reads the groups dynamic metadata)
printf "\nDeploy EnterpriseKgatewayTrafficPolicy ...\n"
kubectl apply -f policies/extauth-transformation-httproute-policy.yaml

popd
