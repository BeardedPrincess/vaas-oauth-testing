#!/bin/bash
source .env

# Set console color variables
RED='\033[0;31m'
GRN='\033[0;32m'
NC='\033[0m' # No Color

# Check the source'd .env
REQUIRED_ENV=("TOKEN_URL" "AUDIENCE" "CLIENT_ID" "CLIENT_SECRET" "SCOPE" "VAAS_TENANT_ID")
MISSING_ENV=""
for var in "${REQUIRED_ENV[@]}"; do
  if [ -z "${!var}" ]; then
    MISSING_ENV="${MISSING_ENV}\t${var}\n"
  fi
done

# If any required entries are missing, exit
if [ -n "$MISSING_ENV" ]; then
  echo -e "${RED}ERROR: Supplied .env file is missing required entries:\n${MISSING_ENV}${NC}"
  echo -e "\nCheck the file .env and compare required entries to .env-SAMPLE"
  exit 1
fi

# Require jq to be installed
which jq 2>&1 > /dev/null
if [ $? -ne 0 ]; then
  echo 'jq is required, but was not found in PATH. Please install jq and try again.'
  exit 2
fi

# Get an access_token from OAuth2 iDP using client_credential flow 
RESPONSE=`curl --silent --request POST --location ${TOKEN_URL} \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=${CLIENT_SECRET}" \
  --data-urlencode "audience=${AUDIENCE}" \
  --data-urlencode "scope=${SCOPE}" \
  --data-urlencode 'grant_type=client_credentials'`

# Check if we got an error from OAuth
ERROR=$(echo "${RESPONSE}" | jq '.error')

if [ "${ERROR}" != "null" ]; then
  echo -e "${RED}ERROR: Request to OAuth2 token endpoint failed: ${NC}"
  echo -e "\t${RESPONSE}"
  exit 3
fi

# Extract just the jwt token
JWT=`echo ${RESPONSE} | jq -r .access_token`
echo $JWT > .jwt

# Create a 'folded' version of the JWT token for display purposes
JWT_PRETTY=`echo ${JWT} | fold -w 60`

# Decode the JWT into json
DECODED_JWT_HEADER=`echo $JWT | jq -R 'split(".") | .[0] | @base64d | fromjson'`
DECODED_JWT_PAYLOAD=`echo $JWT | jq -R 'split(".") | .[1] | @base64d | fromjson'`

# Get issued at time, localized
JWT_IAT=`echo $DECODED_JWT_PAYLOAD | jq -r '.iat'`
JWT_IAT_HUMAN=`date -r ${JWT_IAT} -Iseconds`

# Get expire at time, localized
JWT_EXP=`echo $DECODED_JWT_PAYLOAD | jq -r '.exp'`
JWT_EXP_HUMAN=`date -r ${JWT_EXP} -Iseconds`

# Get the issuer url from the decoded JWT token
JWT_ISSUER=`echo $DECODED_JWT_PAYLOAD | jq -r '.iss'`

# Attempt discovery on the Issuer URL to determine JWKS_URI
JWT_JWKS_URI=`curl --silent --location "${JWT_ISSUER}.well-known/openid-configuration" | jq -r '.jwks_uri'`

# Make some pretty output
echo -e '\n================== JWT & Issuer Details ===================='
echo 'JWT: '
echo -e "${RED}${JWT_PRETTY}${NC}"
echo -e '\nDECODED_JWT_HEADER:'
echo ${DECODED_JWT_HEADER} | jq -C .
echo -e '\nDECODED_JWT_PAYLOAD:'
echo ${DECODED_JWT_PAYLOAD} | jq -C .
echo -e "\nJWT_IAT_HUMAN: ${GRN}${JWT_IAT_HUMAN}${NC}"
echo -e "JWT_EXP_HUMAN: ${GRN}${JWT_EXP_HUMAN}${NC}"
echo -e "JWT_ISSUER: ${GRN}${JWT_ISSUER}${NC}"
echo -e "JWT_JWKS_URI: ${GRN}${JWT_JWKS_URI}${NC}"
echo '============================================================'

echo -e '\n\n============== Sending to VaaS for API Token ==============='
VAAS_RESULT=`curl --silent --location "https://api.venafi.cloud/v1/oauth2/v2.0/${VAAS_TENANT_ID}/token" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "client_assertion=${JWT}" \
    --data-urlencode 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer'`

echo -e "\tResult:\n\t${VAAS_RESULT}"

VAAS_ACCESS_TOKEN=$(echo ${VAAS_RESULT} | jq '.access_token')
if [ "${VAAS_ACCESS_TOKEN}" != "null" ]; then
  export VAAS_ACCESS_TOKEN
  echo -e "\n\n${GRN}VaaS access_token available as \$VAAS_ACCESS_TOKEN${NC}"
fi

echo '===================== TEST VCERT PLAYBOOK ============================'
vcert run -f testPlaybook.yaml -d --force-renew
