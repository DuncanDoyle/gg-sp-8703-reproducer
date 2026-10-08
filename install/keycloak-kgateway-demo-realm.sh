#!/bin/bash

# Provisions the Keycloak 'kgateway-demo' realm used by this reproducer:
#
#   - groups TOTO, TATA and TITI
#   - user 'user1' (password 'password') who is a member of all three groups
#   - public client 'kgateway-client' (Direct Access Grants enabled), with a "Group Membership"
#     protocol mapper that puts a 'groups' claim into the access token:
#
#       "groups": ["TATA", "TITI", "TOTO"]     <-- a JSON array claim
#
# The Keycloak admin API is reached through a temporary port-forward to the Keycloak Service, so this script
# does not depend on the Gateway or on DNS for keycloak.example.com.

set -e

export REALM="kgateway-demo"
export CLIENT_ID="kgateway-client"
KC_ADMIN_PASS=${KC_ADMIN_PASS:-admin}
KC_LOCAL_PORT=${KC_LOCAL_PORT:-18080}
export KEYCLOAK_URL=http://localhost:$KC_LOCAL_PORT

kubectl -n keycloak port-forward svc/keycloak $KC_LOCAL_PORT:80 >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null" EXIT
for i in $(seq 1 30); do
  curl -s -o /dev/null "$KEYCLOAK_URL/realms/master" && break
  sleep 1
done

CURL_OPTS="-s"

kc() {
  # Keycloak admin REST call: kc <METHOD> <path> [json-body]
  curl $CURL_OPTS -X "$1" -H "Authorization: Bearer $KEYCLOAK_TOKEN" -H "Content-Type: application/json" \
    ${3:+-d "$3"} "$KEYCLOAK_URL/admin/realms$2"
}

# Admin token from the master realm.
export KEYCLOAK_TOKEN=$(curl $CURL_OPTS -d "client_id=admin-cli" -d "username=admin" -d "password=$KC_ADMIN_PASS" -d "grant_type=password" "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" | jq -r .access_token)
[[ -z "$KEYCLOAK_TOKEN" || "$KEYCLOAK_TOKEN" == "null" ]] && { echo "Failed to get Keycloak admin token - check that $KEYCLOAK_URL is reachable"; exit 1; }

################################################ Realm ################################################

printf "\nCreating realm: $REALM\n"
kc POST "" "{\"realm\": \"$REALM\", \"enabled\": true}"

################################################ Groups ################################################

for GROUP in TOTO TATA TITI; do
  printf "\nCreating group: $GROUP\n"
  kc POST "/$REALM/groups" "{\"name\": \"$GROUP\"}"
done

################################################ User: user1 ################################################

printf "\nCreating user: user1 (member of TOTO, TATA, TITI)\n"
kc POST "/$REALM/users" "$(cat <<EOM
{
  "username": "user1",
  "email": "user1@example.com",
  "firstName": "User",
  "lastName": "One",
  "emailVerified": true,
  "enabled": true,
  "groups": ["TOTO", "TATA", "TITI"],
  "credentials": [{ "type": "password", "value": "password", "temporary": false }]
}
EOM
)"

################################################ Client: kgateway-client ################################################

# Public client so the test script can use the Resource Owner Password grant with just a client_id.
printf "\nCreating client: $CLIENT_ID\n"
kc POST "/$REALM/clients" "$(cat <<EOM
{
  "clientId": "$CLIENT_ID",
  "publicClient": true,
  "directAccessGrantsEnabled": true,
  "standardFlowEnabled": false,
  "protocolMappers": [
    {
      "name": "groups",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-group-membership-mapper",
      "config": {
        "claim.name": "groups",
        "full.path": "false",
        "access.token.claim": "true",
        "id.token.claim": "true",
        "userinfo.token.claim": "true"
      }
    }
  ]
}
EOM
)"

printf "\nRealm '$REALM' provisioned.\n"
