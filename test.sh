#!/bin/bash

# Reproducer for https://github.com/solo-io/solo-projects/issues/8703
#
# 1. Gets an access token for user1 from Keycloak. Its 'groups' claim is the array ["TATA","TITI","TOTO"].
# 2. ExtAuth validates the token and copies the 'groups' claim into dynamic metadata (as a ListValue).
# 3. /anything/raw:     shows that Inja's dynamic_metadata() returns that array as a JSON *string*.
# 4. /anything/iterate: shows that iterating over the groups in an Inja 'for' loop fails.
#
# Requests go to keycloak.example.com and api.example.com through the Gateway:
#   - GATEWAY_ADDRESS set (e.g. localhost:8080): both hostnames are routed there with curl --connect-to.
#   - GATEWAY_ADDRESS unset and the hostnames reach the Gateway (DNS, /etc/hosts + minikube tunnel): used as-is.
#   - Otherwise: the script opens a temporary port-forward to the Gateway and uses that.

CURL_OPTS="-s"

if [[ -z "$GATEWAY_ADDRESS" ]] && ! curl -s -m 3 -o /dev/null http://keycloak.example.com/realms/kgateway-demo; then
  GW_LOCAL_PORT=${GW_LOCAL_PORT:-18081}
  printf "keycloak.example.com does not reach the Gateway; port-forwarding deploy/gw to localhost:%s\n" "$GW_LOCAL_PORT"
  kubectl -n ingress-gw port-forward deploy/gw $GW_LOCAL_PORT:80 >/dev/null 2>&1 &
  PF_PID=$!
  trap "kill $PF_PID 2>/dev/null" EXIT
  for i in $(seq 1 30); do
    curl -s -o /dev/null localhost:$GW_LOCAL_PORT && break
    sleep 1
  done
  GATEWAY_ADDRESS=localhost:$GW_LOCAL_PORT
fi
[[ -n "$GATEWAY_ADDRESS" ]] && CURL_OPTS="$CURL_OPTS --connect-to ::$GATEWAY_ADDRESS"

TOKEN_RESPONSE=$(curl $CURL_OPTS \
  -d grant_type=password -d client_id=kgateway-client -d username=user1 -d password=password \
  http://keycloak.example.com/realms/kgateway-demo/protocol/openid-connect/token)
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .access_token 2>/dev/null)

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
  echo "Failed to obtain an access token from keycloak.example.com (via ${GATEWAY_ADDRESS:-DNS})."
  echo "Response: ${TOKEN_RESPONSE:-<no response>}"
  echo "Check that install/setup.sh completed and that the 'kgateway-demo' realm exists."
  exit 1
fi

printf "\n=== 1. 'groups' claim in the Keycloak access token (a JSON array) ===\n"
PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d. -f2 | tr '_-' '/+')
# Restore the base64 padding that JWTs strip.
while [ $(( ${#PAYLOAD} % 4 )) -ne 0 ]; do PAYLOAD="$PAYLOAD="; done
echo "$PAYLOAD" | base64 -d | jq -c '{groups}'

printf "\n=== 2. POST /anything/raw: what dynamic_metadata(\"keycloak_atv:groups\", \"envoy.filters.http.ext_authz\") returns ===\n"
printf "Expected: X-Groups-Is-Array=true\n"
printf "Actual:   (see below)\n\n"
curl $CURL_OPTS -X POST -H "Authorization: Bearer $ACCESS_TOKEN" http://api.example.com/anything/raw \
  | jq '.headers | {"X-Groups-Raw", "X-Groups-Is-String", "X-Groups-Is-Array"}'

printf "\n=== 3. POST /anything/iterate: build the contextual_tuples payload with an Inja 'for' loop ===\n"
printf 'Expected: 200, and httpbin echoes this request body:\n'
printf '  {"contextual_tuples":{"tuple_keys":[{"object":"group:TATA"},{"object":"group:TITI"},{"object":"group:TOTO"}]}}\n'
printf "Actual:\n\n"
curl $CURL_OPTS -i -X POST -H "Authorization: Bearer $ACCESS_TOKEN" http://api.example.com/anything/iterate
printf "\n"
