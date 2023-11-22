#!/usr/bin/env sh


# shell colors
C1='\033[0;32m' # green
C2='\033[0;33m' # orange
C3='\033[0;34m' # blue
C4='\033[0;31m' # red
NC='\033[0m'    # No Color


# utility functions
_die() {
    printf "\n${C4}ERROR: %s${NC}\n" "$@"
    exit 1
}

_log() {
    printf "${C3}%s${NC}\n" "$@"
}

_subtit() {
    printf "${C2} > %s${NC}\n" "$@"
}

_tit() {
    echo
    printf "${C1}==== %-20s ====${NC}\n" "$@"
}

_trace() {
    { local trace=0; } 2>/dev/null
    { [ -o xtrace ] && trace=1; } 2>/dev/null
    { [ $DEBUG = 1 ] && set -x; } 2>/dev/null
    "$@"
    { [ $trace == 0 ] && set +x; } 2>/dev/null
}

cargo install bdk-cli --version "0.27.1" --root "./bdk-cli" --features electrum --locked
cargo install rgb-contracts --version "0.10.0-rc.5" --root "./rgb-contracts" --all-features --locked

_tit "Setup"
_log "Remove old files and shutdown docker containers"
docker compose logs bitcoind
# stop services and remove containers
docker compose down

# remove data directories
sudo rm -fr data{0,1,core,index}
sudo rm -fr ~/.bdk-bitcoin/{issuer,receiver}

_log "Set env variables and aliases"

# create data directories
mkdir data{0,1,core,index}

# start services (first time docker images need to be downloaded...)
docker compose up -d


alias bcli="docker compose exec -u blits bitcoind bitcoin-cli -regtest"
alias bdk="bdk-cli/bin/bdk-cli"
alias rgb0="rgb-contracts/bin/rgb -n regtest -d data0"
alias rgb1="rgb-contracts/bin/rgb -n regtest -d data1"


CLOSING_METHOD="opret1st"
CLOSING_METHOD2="opret2nd"
DERIVE_PATH="m/86'/1'/0'/9"
DESC_TYPE="wpkh"
ELECTRUM="localhost:50001"
ELECTRUM_DOCKER="electrs:50001"
CONSIGNMENT="consignment.rgb"
PSBT="tx.psbt"
IFACE="RGB20"


_log "Setup up sender and receiver wallets"
bcli createwallet miner
bcli -generate 103

_log "issuer/sender BDK wallet"
xprv_0=$(bdk key generate | jq -r ".xprv")
xprv_der_0=$( bdk key derive -p "$DERIVE_PATH" -x "$xprv_0" | jq -r ".xprv")
xpub_der_0=$( bdk key derive -p "$DERIVE_PATH" -x "$xprv_0" | jq -r ".xpub")
echo $xprv_0
echo $xprv_der_0
echo $xpub_der_0

_log "receiver BDK wallet"
xprv_1=$(bdk key generate | jq -r ".xprv")
xprv_der_1=$( bdk key derive -p "$DERIVE_PATH" -x "$xprv_1" | jq -r ".xprv")
xpub_der_1=$( bdk key derive -p "$DERIVE_PATH" -x "$xprv_1" | jq -r ".xpub")
echo $xprv_1
echo $xprv_der_1
echo $xpub_der_1


_log "generate addresses"
addr_issue=$(bdk -n regtest wallet -w issuer -d "$DESC_TYPE($xpub_der_0)" get_new_address | jq -r ".address")
addr_change=$(bdk -n regtest wallet -w issuer -d "$DESC_TYPE($xpub_der_0)" get_new_address | jq -r ".address")
addr_receive=$(bdk -n regtest wallet -w receiver -d "$DESC_TYPE($xpub_der_1)" get_new_address | jq -r ".address")
echo $addr_issue
echo $addr_change
echo $addr_receive

_log "fund wallets"
bcli -rpcwallet=miner sendtoaddress "$addr_issue" 1
bcli -rpcwallet=miner sendtoaddress "$addr_receive" 1
bcli -rpcwallet=miner -generate 1


_log "Sync wallets"
bdk -n regtest wallet -w issuer -d "$DESC_TYPE($xpub_der_0)" -s "$ELECTRUM" sync
bdk -n regtest wallet -w receiver -d "$DESC_TYPE($xpub_der_1)" -s "$ELECTRUM" sync


_log "Create outpoint"
# list wallet unspents and gather the outpoints
outpoint_issue=$(bdk -n regtest wallet -w issuer -d "$DESC_TYPE($xpub_der_0)" list_unspent | jq -r ".[0].outpoint")

outpoint_receive=$(bdk -n regtest wallet -w receiver -d "$DESC_TYPE($xpub_der_1)" list_unspent | jq -r ".[0].outpoint")

echo $outpoint_issue
echo $outpoint_receive


_log "Import contracts"
rgb0 import rgb-schemata/schemata/NonInflatableAssets.rgb
# example output:
# Stock file not found, creating default stock
# Wallet file not found, creating new wallet list
# Schema urn:lnp-bp:sc:BEiLYE-am9WhTW1-oK8cpvw4-FEMtzMrf-mKocuGZn-qWK6YF#ginger-parking-nirvana imported to the stash

rgb0 import rgb-schemata/schemata/NonInflatableAssets-RGB20.rgb

# 2nd client (same output as 1st client)
rgb1 import rgb-schemata/schemata/NonInflatableAssets.rgb
rgb1 import rgb-schemata/schemata/NonInflatableAssets-RGB20.rgb

schema=$(rgb0 schemata | cut -d " " -f1)
echo $schema


_log "issue contracts"

sed \
  -e "s/issued_supply/1/" \
  -e "s/created_timestamp/$(date +%s)/" \
  -e "s/closing_method/$CLOSING_METHOD/" \
  -e "s/txid:vout/$outpoint_issue/" \
  contracts/usdt.yaml.template > contracts/usdt.yaml

sed \
  -e "s/issued_supply/1/" \
  -e "s/created_timestamp/$(date +%s)/" \
  -e "s/closing_method/$CLOSING_METHOD2/" \
  -e "s/txid:vout/$outpoint_issue/" \
  contracts/usdt.yaml.template > contracts/usdt2.yaml


_log "issue contract1"
contract_id=$(rgb0 issue "$schema" "$IFACE" contracts/usdt.yaml | cut -d " " -f4)
echo $contract_id
_log "issue contract2"
contract_id2=$(rgb0 issue "$schema" "$IFACE" contracts/usdt2.yaml | cut -d " " -f4)
echo $contract_id2
