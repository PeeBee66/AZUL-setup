#!/bin/bash
# AZUL Keycloak Configuration Script
# Configures: realm, roles, groups, client scopes, clients, test user
set -e

# Source central config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AZUL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${AZUL_DIR}/azul.conf"

KC_PASS=$(kubectl get secret keycloak -n azul-infra -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)
KC_PASS_ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$KC_PASS")
KC_URL="http://localhost:${KC_LOCAL_PORT}"

# Start port-forward
kubectl port-forward svc/keycloak -n azul-infra ${KC_LOCAL_PORT}:8080 &
PF_PID=$!
sleep 4

cleanup() {
    kill $PF_PID 2>/dev/null
    wait $PF_PID 2>/dev/null
}
trap cleanup EXIT

# Get admin token
echo "=== Getting admin token ==="
TOKEN=$(curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "username=admin&password=${KC_PASS_ENCODED}&grant_type=password&client_id=admin-cli" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

if [ -z "$TOKEN" ]; then echo "FAILED to get token"; exit 1; fi
echo "Token obtained (length: ${#TOKEN})"

api() {
    local method=$1 path=$2 data=$3
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "${KC_URL}${path}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/json' \
      ${data:+-d "$data"})
    echo "  $method $path -> $code"
    if [ "$code" -ge 400 ] && [ "$code" != "409" ]; then
        echo "    WARNING: unexpected response $code"
    fi
}

api_get() {
    curl -s "${KC_URL}${1}" -H "Authorization: Bearer ${TOKEN}"
}

echo ""
echo "=== 1. Create azul realm ==="
api POST "/admin/realms" '{"realm":"azul","enabled":true,"displayName":"Azul Malware Repository","accessTokenLifespan":300,"ssoSessionMaxLifespan":36000}'

echo ""
echo "=== 2. Create realm roles ==="
for role in azul-access azul_read azul_admin azul_write s-any s-official; do
    api POST "/admin/realms/azul/roles" "{\"name\":\"${role}\",\"description\":\"Azul role: ${role}\"}"
done

echo ""
echo "=== 3. Create groups ==="
api POST "/admin/realms/azul/groups" '{"name":"general"}'
api POST "/admin/realms/azul/groups" '{"name":"opensearch-admins"}'

echo ""
echo "=== 4. Create 'azul' client scope with realm-roles mapper ==="
api POST "/admin/realms/azul/client-scopes" '{"name":"azul","protocol":"openid-connect","attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"}}'

# Get the scope ID
SCOPE_ID=$(api_get "/admin/realms/azul/client-scopes" | python3 -c "
import sys, json
scopes = json.load(sys.stdin)
for s in scopes:
    if s['name'] == 'azul':
        print(s['id'])
        break
")
echo "  azul scope ID: $SCOPE_ID"

# Add realm-roles mapper to the scope
api POST "/admin/realms/azul/client-scopes/${SCOPE_ID}/protocol-mappers/models" \
    '{"name":"realm-roles","protocol":"openid-connect","protocolMapper":"oidc-usermodel-realm-role-mapper","config":{"multivalued":"true","claim.name":"roles","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}'

# Add subject (sub) mapper — CRITICAL: Keycloak 26.x does not include the 'sub' claim
# by default, and the Azul restapi rejects JWTs without it
api POST "/admin/realms/azul/client-scopes/${SCOPE_ID}/protocol-mappers/models" \
    '{"name":"subject","protocol":"openid-connect","protocolMapper":"oidc-sub-mapper","config":{"id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}'

echo ""
echo "=== 5. Create 'audience' client scope ==="
api POST "/admin/realms/azul/client-scopes" '{"name":"audience","protocol":"openid-connect","attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"}}'

AUDIENCE_SCOPE_ID=$(api_get "/admin/realms/azul/client-scopes" | python3 -c "
import sys, json
scopes = json.load(sys.stdin)
for s in scopes:
    if s['name'] == 'audience':
        print(s['id'])
        break
")
echo "  audience scope ID: $AUDIENCE_SCOPE_ID"

# Add audience mapper — includes 'azul-web' in the aud claim of access tokens
# Without this, the access_token aud is only 'account' and the REST API rejects it as "Invalid audience"
api POST "/admin/realms/azul/client-scopes/${AUDIENCE_SCOPE_ID}/protocol-mappers/models" \
    '{"name":"azul-web-audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"azul-web","id.token.claim":"false","access.token.claim":"true","introspection.token.claim":"true"}}'

echo ""
echo "=== 6. Create azul-web client (public, for Web UI) ==="
api POST "/admin/realms/azul/clients" "{\"clientId\":\"azul-web\",\"enabled\":true,\"publicClient\":true,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":true,\"rootUrl\":\"https://${AZUL_HOST}\",\"redirectUris\":[\"https://${AZUL_HOST}/*\",\"http://localhost:*\"],\"webOrigins\":[\"https://${AZUL_HOST}\",\"*\"],\"defaultClientScopes\":[\"openid\",\"profile\",\"email\",\"azul\",\"audience\"],\"optionalClientScopes\":[\"offline_access\"]}"

# Explicitly add 'roles' and 'offline_access' as optional client scopes via PUT API
# (the optionalClientScopes array in POST body is not always reliably applied by Keycloak)
WEB_CLIENT_UUID=$(api_get "/admin/realms/azul/clients?clientId=azul-web" | python3 -c "
import sys, json
clients = json.load(sys.stdin)
if clients: print(clients[0]['id'])")
echo "  azul-web UUID: $WEB_CLIENT_UUID"

ROLES_SCOPE_ID=$(api_get "/admin/realms/azul/client-scopes" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s['name'] == 'roles':
        print(s['id']); break")
OFFLINE_SCOPE_ID=$(api_get "/admin/realms/azul/client-scopes" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s['name'] == 'offline_access':
        print(s['id']); break")

echo "  Adding 'roles' (${ROLES_SCOPE_ID}) as optional scope..."
api PUT "/admin/realms/azul/clients/${WEB_CLIENT_UUID}/optional-client-scopes/${ROLES_SCOPE_ID}"
echo "  Adding 'offline_access' (${OFFLINE_SCOPE_ID}) as optional scope..."
api PUT "/admin/realms/azul/clients/${WEB_CLIENT_UUID}/optional-client-scopes/${OFFLINE_SCOPE_ID}"

echo ""
echo "=== 7. Create opensearch-dashboards client (confidential) ==="
api POST "/admin/realms/azul/clients" "{\"clientId\":\"opensearch-dashboards\",\"enabled\":true,\"publicClient\":false,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":false,\"rootUrl\":\"https://${OPENSEARCH_HOST}\",\"redirectUris\":[\"https://${OPENSEARCH_HOST}/*\"],\"webOrigins\":[\"https://${OPENSEARCH_HOST}\"],\"secret\":\"opensearch-dashboards-secret\",\"defaultClientScopes\":[\"openid\",\"profile\",\"email\",\"azul\"]}"

echo ""
echo "=== 8. Create azul-service client (service account for API) ==="
api POST "/admin/realms/azul/clients" '{"clientId":"azul-service","enabled":true,"publicClient":false,"serviceAccountsEnabled":true,"standardFlowEnabled":false,"directAccessGrantsEnabled":false,"secret":"azul-service-secret","defaultClientScopes":["openid","profile","azul"]}'

echo ""
echo "=== 9. Create test user: ${TEST_USER} / ${TEST_PASSWORD} ==="
api POST "/admin/realms/azul/users" "{\"username\":\"${TEST_USER}\",\"enabled\":true,\"emailVerified\":true,\"firstName\":\"Test\",\"lastName\":\"User\",\"email\":\"${TEST_USER}@${DOMAIN}\",\"credentials\":[{\"type\":\"password\",\"value\":\"${TEST_PASSWORD}\",\"temporary\":false}]}"

# Get user ID
USER_ID=$(api_get "/admin/realms/azul/users?username=${TEST_USER}" | python3 -c "
import sys, json
users = json.load(sys.stdin)
if users: print(users[0]['id'])
")
echo "  User ID: $USER_ID"

# Get all realm roles and assign them to the user
echo ""
echo "=== 10. Assign all roles to test user ==="
ROLES_JSON=$(api_get "/admin/realms/azul/roles" | python3 -c "
import sys, json
roles = json.load(sys.stdin)
# Filter to only azul-related roles
azul_roles = [r for r in roles if r['name'] in ('azul-access','azul_read','azul_admin','azul_write','s-any','s-official')]
print(json.dumps(azul_roles))
")

curl -s -o /dev/null -w "  Assign roles -> %{http_code}\n" -X POST "${KC_URL}/admin/realms/azul/users/${USER_ID}/role-mappings/realm" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$ROLES_JSON"

# Add user to general group
GROUPS=$(api_get "/admin/realms/azul/groups")
GENERAL_GID=$(echo "$GROUPS" | python3 -c "
import sys, json
groups = json.load(sys.stdin)
for g in groups:
    if g['name'] == 'general':
        print(g['id'])
        break
")
echo "  General group ID: $GENERAL_GID"
api PUT "/admin/realms/azul/users/${USER_ID}/groups/${GENERAL_GID}" '{}'

echo ""
echo "=== 11. Create admin user: ${ADMIN_USER} / ${ADMIN_PASSWORD} ==="
api POST "/admin/realms/azul/users" "{\"username\":\"${ADMIN_USER}\",\"enabled\":true,\"emailVerified\":true,\"firstName\":\"Admin\",\"lastName\":\"User\",\"email\":\"${ADMIN_USER}@${DOMAIN}\",\"credentials\":[{\"type\":\"password\",\"value\":\"${ADMIN_PASSWORD}\",\"temporary\":false}]}"

ADMIN_USER_ID=$(api_get "/admin/realms/azul/users?username=${ADMIN_USER}" | python3 -c "
import sys, json
users = json.load(sys.stdin)
if users: print(users[0]['id'])
")
echo "  Admin User ID: $ADMIN_USER_ID"

curl -s -o /dev/null -w "  Assign roles -> %{http_code}\n" -X POST "${KC_URL}/admin/realms/azul/users/${ADMIN_USER_ID}/role-mappings/realm" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$ROLES_JSON"

# Add admin to opensearch-admins group
OS_ADMIN_GID=$(echo "$GROUPS" | python3 -c "
import sys, json
groups = json.load(sys.stdin)
for g in groups:
    if g['name'] == 'opensearch-admins':
        print(g['id'])
        break
")
api PUT "/admin/realms/azul/users/${ADMIN_USER_ID}/groups/${OS_ADMIN_GID}" '{}'

echo ""
echo "=== 12. Verify configuration ==="
echo "Realm:"
api_get "/admin/realms/azul" | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'  {r[\"realm\"]} (enabled: {r[\"enabled\"]})')"
echo "Roles:"
api_get "/admin/realms/azul/roles" | python3 -c "import sys,json; [print(f'  - {r[\"name\"]}') for r in json.load(sys.stdin)]"
echo "Clients:"
api_get "/admin/realms/azul/clients" | python3 -c "import sys,json; [print(f'  - {c[\"clientId\"]}') for c in json.load(sys.stdin) if not c['clientId'].startswith('account') and c['clientId'] != 'broker' and c['clientId'] != 'realm-management']"
echo "Users:"
api_get "/admin/realms/azul/users" | python3 -c "import sys,json; [print(f'  - {u[\"username\"]}') for u in json.load(sys.stdin)]"

echo ""
echo "=== KEYCLOAK CONFIGURATION COMPLETE ==="
echo ""
echo "OIDC Discovery URL: https://${KEYCLOAK_HOST}/realms/azul/.well-known/openid-configuration"
echo "Authority URL: https://${KEYCLOAK_HOST}/realms/azul"
echo "Client ID (Web UI): azul-web"
echo "Client ID (OpenSearch): opensearch-dashboards (secret: opensearch-dashboards-secret)"
echo "Test user: ${TEST_USER} / ${TEST_PASSWORD}"
echo "Admin user: ${ADMIN_USER} / ${ADMIN_PASSWORD}"
