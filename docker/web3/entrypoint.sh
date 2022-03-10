#!/bin/bash

set -o errexit
#set -o xtrace
PROJECT_DIR="/code"
GODWOKEN_RPC_URL="http://godwoken:8119"
GODWOKEN_WS_RPC_URL="ws://godwoken:8120"
POLYMAN_SERVER_RPC_URL="http://polyjuice:6101"

# import some helper function
source ${PROJECT_DIR}/gw_util.sh

# detect which mode to start godwoken_web3
if [ "$MANUAL_BUILD_WEB3" = true ] ; then 
  echo "manual mode.."
  cd /code/packages/godwoken-web3
else
  echo "prebuild mode.."
  cd /godwoken-web3
fi

# read eth_lock_hash from json config file
LOCKSCRIPTS=${PROJECT_DIR}/workspace/deploy/scripts-deploy-result.json

# wait for godwoken finished its deployment
while true; do
    sleep 3;
    if [[ -f "$LOCKSCRIPTS" ]]; then
      echo 'scripts-deploy-result.json file exits. continue.'
      break
    else
      echo 'keep waitting for godwoken deploy scripts on chain...'
    fi
done
EthAccountLockCodeHash=$(jq -r '.eth_account_lock.script_type_hash' $LOCKSCRIPTS)
PolyjuiceValidatorCodeHash=$(jq -r '.polyjuice_validator.script_type_hash' $LOCKSCRIPTS)
L2SudtValidatorCodeHash=$(jq -r '.l2_sudt_validator.script_type_hash' $LOCKSCRIPTS)
TronAccountLockCodeHash=$(jq -r '.tron_account_lock.script_type_hash' $LOCKSCRIPTS)

# read rollup type hash from config.toml file
CONFIGTOML=${PROJECT_DIR}/workspace/config.toml
# wait for godwoken finished generating config.toml file
while true; do
    sleep 3;
    if [[ -f "$CONFIGTOML" ]]; then
      echo 'config.toml file exits. continue.'
      break
    else
      echo 'config.toml file not exits, keep waitting for godwoken generating config.'
    fi
done
RollupTypeHash=$(awk -F'[ ="]+' '$1 == "rollup_type_hash" { print $2 }' $CONFIGTOML | sed 's/\x27//g')

# wait for polyman main rpc server to start
while true; do
    sleep 2;
    if isPolymanServerRunning "${POLYMAN_SERVER_RPC_URL}";
    then
      break;
    else echo "keep waitting..."
    fi
done
CreatorId=$(get_creator_id_from_polyjuice $POLYMAN_SERVER_RPC_URL)

# create folder for address mapping store
mkdir -p /usr/local/godwoken-web3/address-mapping

if [ "$ENABLE_GW_READONLY_NODE" == true ] ; then
  GODWOKEN_READONLY_JSON_RPC=http://godwoken-readonly:8219
else
  GODWOKEN_READONLY_JSON_RPC=http://godwoken:8119
fi

# TODO: get ETH_ADDRESS_REGISTRY_ACCOUNT_ID from the args of creator_script.args
cat > ./packages/api-server/.env <<EOF
DATABASE_URL=postgres://user:password@postgres:5432/lumos
GODWOKEN_JSON_RPC=http://godwoken:8119
GODWOKEN_READONLY_JSON_RPC=${GODWOKEN_READONLY_JSON_RPC}
ETH_ACCOUNT_LOCK_HASH=$EthAccountLockCodeHash
ROLLUP_TYPE_HASH=$RollupTypeHash
PORT=8024
COMPATIBLE_CHAIN_ID=1984
CREATOR_ACCOUNT_ID=$CreatorId
DEFAULT_FROM_ADDRESS=0x6daf63d8411d6e23552658e3cfb48416a6a2ca78
DEFAULT_FROM_ID=2
ETH_ADDRESS_REGISTRY_ACCOUNT_ID=3
POLYJUICE_VALIDATOR_TYPE_HASH=$PolyjuiceValidatorCodeHash
L2_SUDT_VALIDATOR_SCRIPT_TYPE_HASH=$L2SudtValidatorCodeHash
TRON_ACCOUNT_LOCK_HASH=$TronAccountLockCodeHash
REDIS_URL=redis://redis:6379
CLUSTER_COUNT=1
EOF

# generate indexer config
node scripts/generate-indexer-config.js $GODWOKEN_WS_RPC_URL 
cp indexer-config.toml ${PROJECT_DIR}/workspace/

# start web3 server
cd packages/api-server 
# use:
#  - production mode in prebuilds
#  - debug mode in manual-builds
if [ "$MANUAL_BUILD_WEB3" = true ] ; then 
  DEBUG_LOG=true yarn workspace @godwoken-web3/api-server start
else
  NODE_ENV=production DEBUG=godwoken-web3-api:server pm2 start ./bin/cluster --no-daemon --name gw-web3 --max-memory-restart 1G
  # yarn workspace @godwoken-web3/api-server start:pm2
fi

