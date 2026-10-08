
#!/bin/sh

export ENT_KGATEWAY_VERSION="2.3.5"
export ENT_KGATEWAY_HELM_VALUES_FILE="ent-kgateway-helm-values.yaml"
export K8S_GW_API_VERSION="v1.6.1"
export ENT_KGATEWAY_SYSTEM_NAMESPACE="kgateway-system"

if [ -z "$ENT_KGATEWAY_LICENSE_KEY" ]
then
   echo "Solo Enterprise for Kgateway License Key not specified. Please configure the environment variable 'ENT_KGATEWAY_LICENSE_KEY' with your Solo Enterprise for kgateway License Key."
   exit 1
fi

export ENT_KGATEWAY_CRDS_URL="oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway-crds"
export ENT_KGATEWAY_URL="oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway"

#----------------------------------------- Install Gloo Gateway with K8S Gateway API support -----------------------------------------

printf "\nApply K8S Gateway CRDs ....\n"
# kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$K8S_GW_API_VERSION/standard-install.yaml
# Note: --server-side is a workaround. If not applied, the HTTPRoute CRD will not install.
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$K8S_GW_API_VERSION/experimental-install.yaml


printf "\nInstall Solo Enterprise for Kgateway CRDs ....\n"
helm upgrade --install enterprise-kgateway-crds $ENT_KGATEWAY_CRDS_URL \
    --version $ENT_KGATEWAY_VERSION \
    --namespace $ENT_KGATEWAY_SYSTEM_NAMESPACE \
    --create-namespace \
    --set installExtAuthCRDs=true \
    --set installRateLimitCRDs=true \
    --set installEnterpriseListenerSetCRD=true

printf "\nInstall Solo Enterprise for Kgateway ...\n"
helm upgrade --install enterprise-kgateway $ENT_KGATEWAY_URL \
    --version $ENT_KGATEWAY_VERSION \
    --namespace $ENT_KGATEWAY_SYSTEM_NAMESPACE \
    --create-namespace \
    --set-string licensing.licenseKey=$ENT_KGATEWAY_LICENSE_KEY \
    -f $ENT_KGATEWAY_HELM_VALUES_FILE
#----------------------------------------- Install Keycloak -----------------------------------------
# Keycloak is the OAuth/OIDC provider that issues the access token carrying the 'groups' array claim.

pushd ..

printf "\nInstall Keycloak ...\n"
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
# Allow the keycloak.example.com HTTPRoute (in the keycloak namespace) to attach to the Gateway.
kubectl label namespaces keycloak --overwrite shared-gateway-access="true"

kubectl apply -f keycloak/keycloak-secrets.yaml
kubectl apply -f keycloak/keycloak-db-pv.yaml
kubectl apply -f keycloak/keycloak-postgres.yaml
printf "\nWait for Keycloak Postgres readiness ...\n"
kubectl -n keycloak rollout status deploy/postgres --timeout=300s

kubectl apply -f keycloak/keycloak.yaml
printf "\nWait for Keycloak readiness ...\n"
kubectl -n keycloak rollout status deploy/keycloak --timeout=600s

popd
