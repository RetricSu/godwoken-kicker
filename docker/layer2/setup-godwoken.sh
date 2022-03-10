#!/bin/bash

set -o errexit

WORKSPACE="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
CONFIG_DIR="$WORKSPACE/config"

function start-ckb-miner-at-background() {
    log "start"
    ckb -C $CONFIG_DIR miner &> /dev/null &
}

function start-godwoken-at-background() {
    godwoken run -c $CONFIG_DIR/godwoken-config.toml & # &> /dev/null &
    while true; do
        sleep 1
        result=$(curl http://127.0.0.1:8119 &> /dev/null || echo "godwoken not started")
        if [ "$result" != "godwoken not started" ]; then
            break
        fi
    done
}

# The scripts-config.json file records the names and locations of all scripts
# that have been compiled in docker image. These compiled scripts will be
# deployed, and the deployment result will be stored into scripts-deployment.json.
# 
# To avoid redeploying, this command skips scripts-deployment.json if it already
# exists.
#
# More info: https://github.com/nervosnetwork/godwoken-docker-prebuilds/blob/97729b15093af6e5f002b46a74c549fcc8c28394/Dockerfile#L42-L54
function deploy-scripts() {
    log "start"
    if [ -s "$CONFIG_DIR/scripts-deployment.json" ]; then
        log "$CONFIG_DIR/scripts-deployment.json already exists, skip"
        return 0
    fi
    
    start-ckb-miner-at-background

    RUST_BACKTRACE=full gw-tools deploy-scripts \
        --ckb-rpc http://ckb:8114 \
        -i $CONFIG_DIR/scripts-config.json \
        -o $CONFIG_DIR/scripts-deployment.json \
        -k $PRIVATE_KEY_PATH
    log "Generate file \"$CONFIG_DIR/scripts-deployment.json\""
}

function generate-rollup-config() {
    log "start"
    rollup_config='{
        "l1_sudt_script_type_hash": "L1_SUDT_SCRIPT_TYPE_HASH",
        "l1_sudt_cell_dep": {
            "dep_type": "code",
            "out_point": {
            "tx_hash": "L1_SUDT_CELL_DEP_OUT_POINT_TX_HASH",
            "index": "L1_SUDT_CELL_DEP_OUT_POINT_INDEX"
            }
        },
        "cells_lock": {
            "code_hash": "0x1111111111111111111111111111111111111111111111111111111111111111",
            "hash_type": "type",
            "args": "0x0000000000000000000000000000000000000000"
        },
        "reward_lock": {
            "code_hash": "0x9bd7e06f3ecf4be0f2fcd2188b23f1b9fcc88e5d4b65a8637b17723bbda3cce8",
            "hash_type": "type",
            "args": "0x74e5c89172c5d447819f1629743ef2221df083be"
        },
        "burn_lock": {
            "code_hash": "0x0000000000000000000000000000000000000000000000000000000000000000",
            "hash_type": "data",
            "args": "0x"
        },
        "required_staking_capacity": 10000000000,
        "challenge_maturity_blocks": 100,
        "finality_blocks": 100,
        "reward_burn_rate": 50,
        "compatible_chain_id": 1984,
        "allowed_eoa_type_hashes": [],
        "allowed_contract_type_hashes": []
    }'

    if [ -s "$CONFIG_DIR/rollup-config.json" ]; then
        log "$CONFIG_DIR/rollup-config.json already exists, skip"
        return 0
    fi
    if [ ! -s "$CONFIG_DIR/scripts-deployment.json" ]; then
        log "$CONFIG_DIR/scripts-deployment.json does not exist"
        return 1
    fi

    l1_sudt_script_type_hash=$(get_value2 "$CONFIG_DIR/scripts-deployment.json" "l2_sudt_validator" "script_type_hash")
    l1_sudt_cell_dep_out_point_tx_hash=$(get_value2 "$CONFIG_DIR/scripts-deployment.json" "l2_sudt_validator" "tx_hash")
    l1_sudt_cell_dep_out_point_index=$(get_value2 "$CONFIG_DIR/scripts-deployment.json" "l2_sudt_validator" "index")
    if [ -z "$l1_sudt_script_type_hash" ]; then
        log "Can not find l2_sudt_validator.script_type_hash from $CONFIG_DIR/scripts-deployment.json"
        return 1
    fi

    echo "$rollup_config" \
        | sed "s/L1_SUDT_SCRIPT_TYPE_HASH/$l1_sudt_script_type_hash/g" \
        | sed "s/L1_SUDT_CELL_DEP_OUT_POINT_TX_HASH/$l1_sudt_cell_dep_out_point_tx_hash/g" \
        | sed "s/L1_SUDT_CELL_DEP_OUT_POINT_INDEX/$l1_sudt_cell_dep_out_point_index/g" \
        > $CONFIG_DIR/rollup-config.json
    log "Generate file \"$CONFIG_DIR/rollup-config.json\""
}

function deploy-rollup-genesis() {
    log "start"
    if [ -s "$CONFIG_DIR/rollup-genesis-deployment.json" ]; then
        log "$CONFIG_DIR/rollup-genesis-deployment.json already exists, skip"
        return 0
    fi

    RUST_BACKTRACE=full gw-tools deploy-genesis \
        --ckb-rpc http://ckb:8114 \
        --scripts-deployment-path $CONFIG_DIR/scripts-deployment.json \
        --omni-lock-config-path $CONFIG_DIR/scripts-deployment.json \
        --rollup-config $CONFIG_DIR/rollup-config.json \
        -o $CONFIG_DIR/rollup-genesis-deployment.json \
        -k $PRIVATE_KEY_PATH
    log "Generate file \"$CONFIG_DIR/rollup-genesis-deployment.json\""
}

function generate-godwoken-config() {
    log "start"
    if [ -s "$CONFIG_DIR/godwoken-config.toml" ]; then
        log "$CONFIG_DIR/godwoken-config.toml already exists, skip"
        return 0
    fi

    RUST_BACKTRACE=full gw-tools generate-config \
        --ckb-rpc http://ckb:8114 \
        --ckb-indexer-rpc http://ckb-indexer:8116 \
        -d postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@postgres:5432/$POSTGRES_DB \
        -c $CONFIG_DIR/scripts-config.json \
        --scripts-deployment-path $CONFIG_DIR/scripts-deployment.json \
        --omni-lock-config-path $CONFIG_DIR/scripts-deployment.json \
        -g $CONFIG_DIR/rollup-genesis-deployment.json \
        --rollup-config $CONFIG_DIR/rollup-config.json \
        --privkey-path $PRIVATE_KEY_PATH \
        -o $CONFIG_DIR/godwoken-config.toml \
        --rpc-server-url 0.0.0.0:8119

    # some dirty modification
    if [ ! -z "$GODWOKEN_MODE" ]; then
        sed -i 's#^node_mode = .*$#node_mode = '"'$GODWOKEN_MODE'"'#' $CONFIG_DIR/godwoken-config.toml
    fi
    if [ ! -z "$STORE_PATH" ]; then
        sed -i 's#^path = .*$#path = '"'$STORE_PATH'"'#' $CONFIG_DIR/godwoken-config.toml
    fi
    sed -i 's#enable_methods = \[\]#err_receipt_ws_listen = '"'0.0.0.0:8120'"'#' $CONFIG_DIR/godwoken-config.toml
    echo ""                                                                                 >> $CONFIG_DIR/godwoken-config.toml
    echo "[eth_eoa_mapping_config.register_wallet_config]"                                  >> $CONFIG_DIR/godwoken-config.toml
    echo "privkey_path = '$META_USER_PRIVATE_KEY_PATH'"                                     >> $CONFIG_DIR/godwoken-config.toml
    echo "[eth_eoa_mapping_config.register_wallet_config.lock]"                             >> $CONFIG_DIR/godwoken-config.toml
    echo "## The private key is godwoken-kicker/config/meta_user_private_key"               >> $CONFIG_DIR/godwoken-config.toml
    echo "args = '0x952809177232d0dba355ba5b6f4eaca39cc57746'"                              >> $CONFIG_DIR/godwoken-config.toml
    echo "hash_type = 'type'"                                                               >> $CONFIG_DIR/godwoken-config.toml
    echo "code_hash = '0x9bd7e06f3ecf4be0f2fcd2188b23f1b9fcc88e5d4b65a8637b17723bbda3cce8'" >> $CONFIG_DIR/godwoken-config.toml

    log "Generate file \"$CONFIG_DIR/godwoken-config.toml\""
}

function deposit-and-create-polyjuice-creator-account() {
    log "start"
    if [ -s "$CONFIG_DIR/polyjuice-creator-account-id" ]; then
        log "$CONFIG_DIR/polyjuice-creator-account-id already exists, skip"
        return 0
    fi

    # To complete the rest steps, we have to start a temporary godwoken
    # process in background. This temporary process will dead as "setup-godwoken"
    # docker-compose service exit.
    start-godwoken-at-background

    # Deposit and create account for $PRIVATE_KEY_PATH
    RUST_BACKTRACE=full gw-tools deposit-ckb \
        --privkey-path $PRIVATE_KEY_PATH \
        --godwoken-rpc-url http://127.0.0.1:8119 \
        --ckb-rpc http://ckb:8114 \
        --scripts-deployment-path $CONFIG_DIR/scripts-deployment.json \
        --config-path $CONFIG_DIR/godwoken-config.toml \
        --capacity 1000
    RUST_BACKTRACE=full gw-tools create-creator-account \
        --privkey-path $PRIVATE_KEY_PATH \
        --godwoken-rpc-url http://127.0.0.1:8119 \
        --scripts-deployment-path $CONFIG_DIR/scripts-deployment.json \
        --config-path $CONFIG_DIR/godwoken-config.toml \
        --sudt-id 1 \
    > /var/tmp/gw-tools.log 2>&1
    cat /var/tmp/gw-tools.log
    tail -n 1 /var/tmp/gw-tools.log | grep -oE '[0-9]+$' > $CONFIG_DIR/polyjuice-creator-account-id

    # Deposit and create account for $META_USER_PRIVATE_KEY_PATH
    RUST_BACKTRACE=full gw-tools deposit-ckb \
        --privkey-path $META_USER_PRIVATE_KEY_PATH \
        --godwoken-rpc-url http://127.0.0.1:8119 \
        --ckb-rpc http://ckb:8114 \
        --scripts-deployment-path $CONFIG_DIR/scripts-deployment.json \
        --config-path $CONFIG_DIR/godwoken-config.toml \
        --capacity 1000
    RUST_BACKTRACE=full gw-tools create-creator-account \
        --privkey-path $META_USER_PRIVATE_KEY_PATH \
        --godwoken-rpc-url http://127.0.0.1:8119 \
        --scripts-deployment-path $CONFIG_DIR/scripts-deployment.json \
        --config-path $CONFIG_DIR/godwoken-config.toml \
        --sudt-id 1

    log "Generate file \"$CONFIG_DIR/polyjuice-creator-account-id\""
}

function generate-web3-config() {
    log "start"
    if [ -s "$CONFIG_DIR/web3-config.env" ]; then
        log "$CONFIG_DIR/web3-config.env already exists, skip"
        return 0
    fi

    creator_account_id=$(cat $CONFIG_DIR/polyjuice-creator-account-id)
    if [ $creator_account_id != "4" ]; then
        log "cat $CONFIG_DIR/polyjuice-creator-account-id ==> $creator_account_id"
        log "Error: The polyjuice-creator-account-id is expected to be 4, but got $creator_account_id"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        apt-get install -y jq &>/dev/null
    fi

    # TODO: get ETH_ADDRESS_REGISTRY_ACCOUNT_ID from the args of creator_script.args
    cat <<EOF > $CONFIG_DIR/web3-config.env
ROLLUP_TYPE_HASH=$(jq -r '.rollup_type_hash' $CONFIG_DIR/rollup-genesis-deployment.json)
ETH_ACCOUNT_LOCK_HASH=$(jq -r '.eth_account_lock.script_type_hash' $CONFIG_DIR/scripts-deployment.json)
POLYJUICE_VALIDATOR_TYPE_HASH=$(jq -r '.polyjuice_validator.script_type_hash' $CONFIG_DIR/scripts-deployment.json)
L2_SUDT_VALIDATOR_SCRIPT_TYPE_HASH=$(jq -r '.l2_sudt_validator.script_type_hash' $CONFIG_DIR/scripts-deployment.json)
TRON_ACCOUNT_LOCK_HASH=$(jq -r '.tron_account_lock.script_type_hash' $CONFIG_DIR/scripts-deployment.json)

DATABASE_URL=postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@postgres:5432/$POSTGRES_DB
REDIS_URL=redis://redis:6379
GODWOKEN_JSON_RPC=http://godwoken:8119
GODWOKEN_WS_RPC_URL=ws://godwoken:8120
PORT=8024

# The `CREATOR_ACCOUNT_ID` is always be `4` as the first polyjuice account;
# the `COMPATIBLE_CHAIN_ID` is a random number;
# then we can calculate the `CHAIN_ID` by:
#
# ```
# eth_chain_id = [0; 24] | rollup_config.compatible_chain_id::u32 | creator_account_id::u32
# ```
#
# More about chain id:
# * https://github.com/nervosnetwork/godwoken/pull/561
# * https://eips.ethereum.org/EIPS/eip-1344#specification
CREATOR_ACCOUNT_ID=4
COMPATIBLE_CHAIN_ID=1984
CHAIN_ID=8521215115268

# When requests "executeTransaction" RPC interface, the RawL2Transaction's
# signature can be omit. Therefore we fill the RawL2Transaction.from_id
# with this DEFAULT_FROM_ID (corresponding to DEFAULT_FROM_ADDRESS).
DEFAULT_FROM_ADDRESS=0x6daf63d8411d6e23552658e3cfb48416a6a2ca78
DEFAULT_FROM_ID=2

ETH_ADDRESS_REGISTRY_ACCOUNT_ID=3
EOF

    log "Generate file \"$CONFIG_DIR/web3-config.env\""
}

function generate-web3-indexer-config() {
    log "start"
    if [ -s "$CONFIG_DIR/web3-indexer-config.toml" ]; then
        log "$CONFIG_DIR/web3-indexer-config.toml already exists, skip"
        return 0
    fi

    source $CONFIG_DIR/web3-config.env
    cat <<EOF > $CONFIG_DIR/web3-indexer-config.toml
l2_sudt_type_script_hash="$L2_SUDT_VALIDATOR_SCRIPT_TYPE_HASH"
polyjuice_type_script_hash="$POLYJUICE_VALIDATOR_TYPE_HASH"
rollup_type_hash="$ROLLUP_TYPE_HASH"
eth_account_lock_hash="$ETH_ACCOUNT_LOCK_HASH"
tron_account_lock_hash="$TRON_ACCOUNT_LOCK_HASH"
godwoken_rpc_url="$GODWOKEN_JSON_RPC"
pg_url="$DATABASE_URL"
ws_rpc_url="$GODWOKEN_WS_RPC_URL"
EOF

    log "Generate file \"$CONFIG_DIR/web3-indexer-config.toml\""
}

# TODO replace with jq
function get_value2() {
    filepath=$1
    key1=$2
    key2=$3

    echo "$(cat $filepath)" | grep -Pzo ''$key1'[^}]*'$key2'":[\s]*"\K[^"]*'
}

function log() {
    echo "[${FUNCNAME[1]}] $1"
}

function main() {
    command=$1
    case $command in
        "all")
            deploy-scripts
            generate-rollup-config
            deploy-rollup-genesis
            generate-godwoken-config
            deposit-and-create-polyjuice-creator-account
            generate-web3-config
            generate-web3-indexer-config
            ;;
        "reset")
            rm -f $CONFIG_DIR/scripts-deployment.json
            rm -f $CONFIG_DIR/rollup-config.json
            rm -f $CONFIG_DIR/rollup-genesis-deployment.json
            rm -f $CONFIG_DIR/godwoken-config.toml
            rm -f $CONFIG_DIR/polyjuice-creator-account-id
            rm -f $CONFIG_DIR/web3-config.env
            rm -f $CONFIG_DIR/web3-indexer-config.toml
            rm -rf $WORKSPACE/data
            log "rm -f $CONFIG_DIR/scripts-deployment.json"
            log "rm -f $CONFIG_DIR/rollup-config.json"
            log "rm -f $CONFIG_DIR/rollup-genesis-deployment.json"
            log "rm -f $CONFIG_DIR/godwoken-config.toml"
            log "rm -f $CONFIG_DIR/polyjuice-creator-account-id"
            log "rm -f $CONFIG_DIR/web3-config.env"
            log "rm -f $CONFIG_DIR/web3-indexer-config.toml"
            log "rm -rf $WORKSPACE/data"
            ;;
        *)
            log "ERROR: unknown command"
            exit 1
            ;;
    esac
}

main "$1"
