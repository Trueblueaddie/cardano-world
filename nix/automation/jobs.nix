{
  inputs,
  cell,
}: let
  inherit (inputs) nixpkgs;
  inherit (inputs.cells.cardano) packages library nixosProfiles;
  inherit (inputs.bitte-cells._writers.library) writeShellApplication;
  inherit (inputs.nixpkgs.lib.strings) fileContents;
in {
  materialize-node = writeShellApplication {
    name = "materialize-node";
    text = ''
      exec ${packages.cardano-node.passthru.generateMaterialized} ./nix/cardano/packages/materialized
    '';
  };
  # run-local-node = let
  #   envName = "testnet";
  #   config =
  #     library.evalNodeConfig envName
  #     nixosProfiles.run-node-testnet;
  #   cmd = writeShellApplication {
  #     name = "run-node";
  #     text =
  #       (fileContents ./../entrypoints/node-entrypoint.sh)
  #       + "\n"
  #       + config.script;
  #     env = {
  #       inherit (config) stateDir socketPath;
  #       inherit envName;
  #     };
  #     runtimeInputs = [
  #       packages.cardano-node
  #       packages.cardano-cli
  #       # TODO: take from somewhere else than aws, e.g. an iohk hydra published path or similar
  #       nixpkgs.awscli2
  #       nixpkgs.gnutar
  #       nixpkgs.gzip
  #     ];
  #   };
  # in {
  #   command = "run-node";
  #   dependencies = [cmd];
  # };
  # push-snapshot-node = let
  #   envName = "testnet";
  #   config =
  #     library.evalNodeConfig envName
  #     nixosProfiles.run-node-testnet;
  #   cmd = writeShellApplication {
  #     name = "push-snapshot";
  #     text = fileContents ./push-node-snapshot.sh;
  #     env = {
  #       inherit (config) stateDir;
  #       inherit envName;
  #     };
  #     runtimeInputs = [nixpkgs.awscli2 nixpkgs.gnutar nixpkgs.gzip nixpkgs.coreutils];
  #   };
  # in {
  #   command = "push-snapshot";
  #   dependencies = [cmd];
  # };
  gen-custom-node-config = writeShellApplication {
    name = "gen-custom-node-config";
    runtimeInputs = [packages.cardano-cli nixpkgs.coreutils];
    text = ''
      genesis_dir="$PRJ_ROOT/workbench/custom"
      mkdir -p "$genesis_dir"
      cardano-cli genesis create-cardano \
        --genesis-dir "$genesis_dir" \
        --gen-genesis-keys 3 \
        --supply 30000000000000000 \
        --testnet-magic 9 \
        --slot-coefficient 0.05 \
        --byron-template "$PRJ_ROOT"/nix/cardano/environments/testnet-template/byron.json \
        --shelley-template "$PRJ_ROOT"/nix/cardano/environments/testnet-template/shelley.json \
        --alonzo-template "$PRJ_ROOT"/nix/cardano/environments/testnet/alonzo-genesis.json \
        --node-config-template "$PRJ_ROOT"/nix/cardano/environments/testnet-template/config.json \
        --security-param 36 \
        --slot-length 1000 \
        --start-time "$(date --utc +"%Y-%m-%dT%H:%M:%SZ" --date " now +30 min")"
    '';
  };
  gen-custom-kv-config =
    writeShellApplication {
      name = "gen-custom-kv-config";
      runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
      text = ''
        genesis_dir="$PRJ_ROOT/workbench/custom"
        mkdir -p "$PRJ_ROOT/nix/cloud/kv/consul/cardano"
        mkdir -p "$PRJ_ROOT/nix/cloud/kv/vault/cardano/vasil-qa"
        pushd "$genesis_dir"
          jq -n \
            --arg byron "$(base64 -w 0 < byron-genesis.json)" \
            --arg shelley "$(base64 -w 0 < shelley-genesis.json)" \
            --arg alonzo "$(base64 -w 0 < alonzo-genesis.json)" \
            --argjson config "$(< node-config.json)" \
            '{byronGenesisBlob: $byron, shelleyGenesisBlob: $shelley, alonzoGenesisBlob: $alonzo, nodeConfig: $config}' \
          > config.json
          cp config.json "$PRJ_ROOT/nix/cloud/kv/consul/cardano/vasil-qa.json"
          pushd delegate-keys
            for i in {0..2}; do
              jq -n \
                --argjson cold "$(<shelley."00$i".skey)" \
                --argjson vrf "$(<shelley."00$i".vrf.skey)" \
                --argjson kes "$(<shelley."00$i".kes.skey)" \
                --argjson opcert "$(<shelley."00$i".opcert.json)" \
                --argjson counter "$(<shelley."00$i".counter.json)" \
                --argjson byron_cert "$(<byron."00$i".cert.json)" \
                '{
                  "kes.skey": $kes,
                  "vrf.skey": $vrf,
                  "opcert.json": $opcert,
                  "byron.cert.json": $byron_cert,
                  "cold.skey": $cold,
                  "cold.counter": $counter
                }' > "bft-$i.json"
                cp "bft-$i.json" "$PRJ_ROOT/nix/cloud/kv/vault/cardano/vasil-qa"
            done
          popd
          pushd "$PRJ_ROOT/nix/cloud/kv/vault/cardano/vasil-qa"
            for i in {0..2}; do
              sops -e "bft-$i.json" > "bft-$i.enc.json" && rm "bft-$i.json"
            done
          popd
        popd
      '';
    }
    // {after = ["gen-custom-node-config"];};
  push-custom-kv-config =
    writeShellApplication {
      name = "push-custom-kv-config";
      runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
      text = ''
        nix run .#clusters.cardano.tf.hydrate-app.plan
        nix run .#clusters.cardano.tf.hydrate-app.apply
      '';
    }
    // {after = ["gen-custom-kv-config"];};
  create-stake-pools = writeShellApplication {
    name = "create-stake-pools";
    runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
    text = ''
      # Inputs: $PAYMENT_KEY, $NUM_POOLS, $START_INDEX, $STAKE_POOL_OUTPUT_DIR, $POOL_RELAY, $POOL_RELAY_PORT
      WITNESSES=$(("$NUM_POOLS" * 2 + 1))
      END_INDEX=$(("$START_INDEX" + "$NUM_POOLS"))
      CHANGE_ADDRESS=$(cardano-cli address build --payment-verification-key-file "$PAYMENT_KEY".vkey --testnet-magic "$TESTNET_MAGIC")

      mkdir -p "$STAKE_POOL_OUTPUT_DIR"

      # generate wallet in control of all the funds delegated to the stake pools
      cardano-address recovery-phrase generate > "$STAKE_POOL_OUTPUT_DIR"/owner.mnemonic
      # extract reward address vkey
      cardano-address key from-recovery-phrase Shelley < "$STAKE_POOL_OUTPUT_DIR"/owner.mnemonic \
        | cardano-address key child 1852H/1815H/"0"H/2/0 \
        | cardano-cli key convert-cardano-address-key --shelley-stake-key \
            --signing-key-file /dev/stdin --out-file /dev/stdout \
        | cardano-cli key verification-key --signing-key-file /dev/stdin \
            --verification-key-file /dev/stdout \
        | cardano-cli key non-extended-key \
            --extended-verification-key-file /dev/stdin \
            --verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-0-reward-stake.vkey
      for ((i="$START_INDEX"; i < "$END_INDEX"; i++))
      do
        # extract stake skey/vkey needed for pool registration and delegation
        cardano-address key from-recovery-phrase Shelley < "$STAKE_POOL_OUTPUT_DIR"/owner.mnemonic \
          | cardano-address key child 1852H/1815H/"$i"H/2/0 \
          | cardano-cli key convert-cardano-address-key --shelley-stake-key \
              --signing-key-file /dev/stdin \
              --out-file /dev/stdout \
          | tee "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.skey \
          | cardano-cli key verification-key \
              --signing-key-file /dev/stdin \
              --verification-key-file /dev/stdout \
          | cardano-cli key non-extended-key \
              --extended-verification-key-file /dev/stdin \
              --verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.vkey
        # generate cold, vrf and kes keys
        cardano-cli node key-gen \
          --cold-signing-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.skey \
          --verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.vkey \
          --operational-certificate-issue-counter-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.counter
        cardano-cli node key-gen-VRF \
          --signing-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-vrf.skey \
          --verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-vrf.vkey
        cardano-cli node key-gen-KES \
          --signing-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-kes.skey \
          --verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-kes.vkey
        # generate opcert
        cardano-cli node issue-op-cert \
          --kes-period 0 \
          --kes-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-kes.vkey \
          --operational-certificate-issue-counter-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.counter \
          --cold-signing-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.skey \
          --out-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i".opcert
      # generate stake registration and delegation certificate
        cardano-cli stake-address registration-certificate \
          --stake-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.vkey \
          --out-file sp-"$i"-owner-registration.cert
        cardano-cli stake-address delegation-certificate \
          --cold-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.vkey \
          --stake-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.vkey \
          --out-file sp-"$i"-owner-delegation.cert
      # generate stake pool registration certificate
        cardano-cli stake-pool registration-certificate \
          --testnet-magic "$TESTNET_MAGIC" \
          --cold-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.vkey \
          --pool-cost 500000000 \
          --pool-margin 1 \
          --pool-owner-stake-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.vkey \
          --pool-pledge 100000000000000 \
          --single-host-pool-relay "$POOL_RELAY" \
          --pool-relay-port "$POOL_RELAY_PORT" \
          --pool-reward-account-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-0-reward-stake.vkey \
          --vrf-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-vrf.vkey \
          --out-file sp-"$i"-registration.cert
      done
      # generate transaction
      TXIN=$(cardano-cli query utxo --address "$CHANGE_ADDRESS" --testnet-magic "$TESTNET_MAGIC" --out-file /dev/stdout \
              | jq -r 'to_entries[0]|.key'
      )
      # generate arrays needed for build/sign commands
      BUILD_TX_ARGS=()
      SIGN_TX_ARGS=()
      for ((i="$START_INDEX"; i < "$END_INDEX"; i++))
      do
        STAKE_POOL_ADDR=$(cardano-cli address build --payment-verification-key-file "$PAYMENT_KEY".vkey --stake-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.vkey --testnet-magic "$TESTNET_MAGIC")
        BUILD_TX_ARGS+=("--tx-out" "$STAKE_POOL_ADDR+100000000000000")
        BUILD_TX_ARGS+=("--certificate-file" "sp-$i-owner-registration.cert")
        BUILD_TX_ARGS+=("--certificate-file" "sp-$i-registration.cert")
        BUILD_TX_ARGS+=("--certificate-file" "sp-$i-owner-delegation.cert")
        SIGN_TX_ARGS+=("--signing-key-file" "$STAKE_POOL_OUTPUT_DIR/sp-$i-cold.skey")
        SIGN_TX_ARGS+=("--signing-key-file" "$STAKE_POOL_OUTPUT_DIR/sp-$i-owner-stake.skey")
      done

      cardano-cli transaction build \
        --tx-in "$TXIN" \
        --change-address "$CHANGE_ADDRESS" \
        --witness-override "$WITNESSES" \
        "''${BUILD_TX_ARGS[@]}" \
        --testnet-magic "$TESTNET_MAGIC" \
        --out-file tx-pool-reg.txbody
      cardano-cli transaction sign \
        --tx-body-file tx-pool-reg.txbody \
        --out-file tx-pool-reg.txsigned \
        --signing-key-file "$PAYMENT_KEY".skey \
        "''${SIGN_TX_ARGS[@]}"
      cardano-cli transaction submit --testnet-magic "$TESTNET_MAGIC" --tx-file tx-pool-reg.txsigned
    '';
  };
  gen-custom-kv-config-pools =
    writeShellApplication {
      name = "gen-custom-kv-config-pools";
      runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
      text = ''
        # Inputs: $NUM_POOLS, $START_INDEX, $STAKE_POOL_DIR
        END_INDEX=$(("$START_INDEX" + "$NUM_POOLS"))
        mkdir -p "$PRJ_ROOT/nix/cloud/kv/vault/cardano/vasil-qa"
        pushd "$STAKE_POOL_DIR"
          for ((i="$START_INDEX"; i < "$END_INDEX"; i++))
          do
            jq -n \
              --argjson cold    "$(< sp-"$i"-cold.skey)" \
              --argjson vrf     "$(< sp-"$i"-vrf.skey)" \
              --argjson kes     "$(< sp-"$i"-kes.skey)" \
              --argjson opcert  "$(< sp-"$i".opcert)" \
              --argjson counter "$(< sp-"$i"-cold.counter)" \
              '{
                "kes.skey": $kes,
                "vrf.skey": $vrf,
                "opcert.json": $opcert,
                "cold.skey": $cold,
                "cold.counter": $counter
              }' > "$PRJ_ROOT/nix/cloud/kv/vault/cardano/vasil-qa/sp-$i.json"
          done
        popd
        pushd "$PRJ_ROOT/nix/cloud/kv/vault/cardano/vasil-qa"
          for ((i="$START_INDEX"; i < "$END_INDEX"; i++))
          do
            sops -e "sp-$i.json" > "sp-$i.enc.json" && rm "sp-$i.json"
          done
        popd
      '';
    }
    // {after = ["gen-custom-node-config"];};
  move-genesis-utxo = writeShellApplication {
    name = "move-genesis-utxo";
    runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
    text = ''
      # Inputs: $PAYMENT_ADDRESS, $BYRON_SIGNING_KEY, $TESTNET_MAGIC
      BYRON_UTXO=$(cardano-cli query utxo --whole-utxo --testnet-magic "$TESTNET_MAGIC" --out-file /dev/stdout|jq \
        'to_entries[]|
        {"txin": .key, "address": .value.address, "amount": .value.value.lovelace}
        |select(.amount > 0)
      ')
      FEE=200000
      SUPPLY=$(echo "$BYRON_UTXO"|jq -r '.amount - 200000')
      BYRON_ADDRESS=$(echo "$BYRON_UTXO"|jq -r '.address')
      TXIN=$(echo "$BYRON_UTXO"|jq -r '.txin')

      cardano-cli transaction build-raw --tx-in "$TXIN" --tx-out "$PAYMENT_ADDRESS+$SUPPLY" --fee "$FEE" --out-file tx-byron.txbody
      cardano-cli transaction sign --tx-body-file tx-byron.txbody --out-file tx-byron.txsigned --address "$BYRON_ADDRESS" --signing-key-file "$BYRON_SIGNING_KEY"
      cardano-cli transaction submit --testnet-magic "$TESTNET_MAGIC" --tx-file tx-byron.txsigned
    '';
  };
}
