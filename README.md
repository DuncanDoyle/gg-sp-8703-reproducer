# Inja `dynamic_metadata()` returns array metadata as a string, so it cannot be iterated

Reproducer for https://github.com/solo-io/solo-projects/issues/8703.

ExtAuth copies a JWT claim that holds an array (`groups`) into Envoy dynamic metadata as a native list. The Inja `dynamic_metadata()` function in the transformation filter returns that list as a JSON **string** (`'["TATA","TITI","TOTO"]'`). Because it isn't an array, a `{% for %}` loop over it fails with `object must be an array`, and no transformation template can build the structured payload a downstream service needs:

```json
{"contextual_tuples": {"tuple_keys": [{"object": "group:TATA"}, {"object": "group:TITI"}, {"object": "group:TOTO"}]}}
```

## Versions

| Component | Version |
|---|---|
| Solo Enterprise for kgateway | 2.3.5 |
| kgateway OSS (base of SEFK 2.3.5) | v2.4.6-0.20260918002548-3b7c9e0b69f3 |
| Kubernetes Gateway API | v1.6.1 |
| ext-auth-service (as deployed) | 0.86.3 |
| Keycloak | 22.0.5 |
| Kubernetes (minikube) | v1.34.7 |

Built and verified: 2026-10-08.

## How it works

```
Keycloak ──token: "groups": ["TATA","TITI","TOTO"]──▶ curl
curl ──Bearer token──▶ Gateway
   ext_authz (AuthConfig oauth-atv-auth)
     dynamicMetadataFromClaims: groups -> metadata envoy.filters.http.ext_authz / keycloak_atv / groups  (ListValue)
   transformation, 'regular' stage (runs after ext_authz)
     dynamic_metadata("keycloak_atv:groups", "envoy.filters.http.ext_authz")  -> '["TATA","TITI","TOTO"]'  (string!)
   ──▶ httpbin /anything (echoes the transformed request)
```

The resources that matter:

- `policies/authconfig/oauth-atv-authconfig.yaml` validates the access token and maps the `groups` claim to dynamic metadata.
- `policies/extauth-transformation-httproute-policy.yaml` attaches ExtAuth and two request transformations to the `api.example.com` route:
  - `/anything/raw` writes the `dynamic_metadata()` value and Inja's `isString()` / `isArray()` results into request headers, which httpbin echoes back.
  - `/anything/iterate` is the use case from the issue: a `for` loop over the groups that builds `contextual_tuples`.
- `install/keycloak-kgateway-demo-realm.sh` creates the `kgateway-demo` realm: groups `TOTO`, `TATA` and `TITI`; user `user1` / `password`, who is a member of all three; and the public client `kgateway-client`, whose Group Membership mapper emits the `groups` claim.

## Steps to reproduce

Prerequisites: a Kubernetes cluster (e.g. minikube), `helm`, `jq`, and `ENT_KGATEWAY_LICENSE_KEY` exported.

```sh
# 1. Install Gateway API CRDs, Solo Enterprise for kgateway 2.3.5 and Keycloak
cd install
./install-ent-kgateway-with-helm.sh

# 2. Deploy Gateway, httpbin, routes, the Keycloak realm, the AuthConfig and the policy
./setup.sh
cd ..

# 3. Run the reproducer
./test.sh
```

`test.sh` calls `keycloak.example.com` and `api.example.com` through the Gateway. If those hostnames don't reach it (no DNS/hosts entry, or no `minikube tunnel` for the LoadBalancer Service), the script opens a temporary port-forward to `deploy/gw` itself. To use an existing port-forward or address instead, set `GATEWAY_ADDRESS` (e.g. `GATEWAY_ADDRESS=localhost:8080 ./test.sh`).

`setup.sh` provisions the Keycloak realm through a temporary port-forward to the Keycloak Service. It stops before applying the AuthConfig if that step fails, because ExtAuth rejects an AuthConfig whose JWKS URL returns 404 and doesn't retry until the AuthConfig changes.

## Expected behavior

`dynamic_metadata()` exposes array metadata as an array, or a function such as `json_parse()` exists to convert the string into one. The `for` loop renders, and httpbin receives:

```json
{"contextual_tuples": {"tuple_keys": [{"object": "group:TATA"}, {"object": "group:TITI"}, {"object": "group:TOTO"}]}}
```

## Actual behavior

Output of `./test.sh`:

```
=== 1. 'groups' claim in the Keycloak access token (a JSON array) ===
{"groups":["TATA","TITI","TOTO"]}

=== 2. POST /anything/raw: what dynamic_metadata("keycloak_atv:groups", "envoy.filters.http.ext_authz") returns ===
Expected: X-Groups-Is-Array=true
{
  "X-Groups-Raw": [ "[\"TATA\",\"TITI\",\"TOTO\"]" ],
  "X-Groups-Is-String": [ "true" ],
  "X-Groups-Is-Array": [ "false" ]
}

=== 3. POST /anything/iterate: build the contextual_tuples payload with an Inja 'for' loop ===
HTTP/1.1 400 Bad Request
...
bad request: [inja.exception.render_error] (at 2:52) object must be an array
```

The value is present and correct, but it's a string. The request never reaches the backend.

> **Pitfall when adapting this reproducer:** a metadata key that doesn't exist also makes `dynamic_metadata()` return `""`, which produces the *same* `object must be an array` error. ExtAuth nests claim metadata under the AuthConfig step name (`keycloak_atv:groups`, not `groups`). Check `X-Groups-Raw` before concluding you hit this bug.

## Root cause

- ExtAuth stores the claim value unchanged in a `structpb.Struct`, so the array stays a `ListValue`. See [`pkg/config/utils/claims.go#L35-L54`](https://github.com/solo-io/ext-auth-service/blob/f49125304b7e/pkg/config/utils/claims.go#L35-L54). It then nests it under the auth step name: [`pkg/chain/chain.go#L559-L564`](https://github.com/solo-io/ext-auth-service/blob/f49125304b7e/pkg/chain/chain.go#L559-L564).
- The envoy-gloo transformation filter's `parse_metadata()`, which backs `dynamic_metadata()`, `cluster_metadata()` and `endpoint_metadata()`, serialises a `ListValue` and a `StructValue` with `MessageToJsonString` and returns the result as an Inja string: [`inja_transformer.cc#L500-L511`](https://github.com/solo-io/envoy-gloo/blob/2fac0b83e703/source/extensions/filters/http/transformation/inja_transformer.cc#L500-L511).

So the data is a list all the way to the transformation filter, which then stringifies it. Inja has no builtin to parse a JSON string, so a template can't recover the array.

## Cleanup

```sh
kubectl delete -f policies/extauth-transformation-httproute-policy.yaml -f policies/authconfig/oauth-atv-authconfig.yaml
```
