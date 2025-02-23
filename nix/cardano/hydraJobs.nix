{ inputs
, cell
,
}:
let
  inherit (inputs) nixpkgs cells;
  inherit (nixpkgs) lib;
  inherit (nixpkgs.stdenv) hostPlatform;
  inherit (cells.automation.jobs) mkHydraRequiredJob;
  inherit (cell.packages) project nodeProject ogmiosProject;
  baseJobs = {
    world = {
      inherit (project) exes checks benchmarks;
      profiled = lib.genAttrs (lib.optionals (!hostPlatform.isDarwin) [ "cardano-new-faucet" ]) (n:
        project.exes.${n}.passthru.profiled
      );
      internal = {
        inherit (project) roots plan-nix;
      };
    };
    node = {
      inherit (nodeProject) exes checks benchmarks release;
      profiled = lib.genAttrs ([ "locli" ] ++ lib.optionals (!hostPlatform.isDarwin) [ "cardano-node" "tx-generator" ]) (n:
        nodeProject.exes.${n}.passthru.profiled
      );
      internal = {
        inherit (nodeProject) roots plan-nix;
      };
    };
    ogmios = {
      inherit (ogmiosProject) exes;
      internal = {
        inherit (ogmiosProject) roots plan-nix;
      };
    };
  };
  jobs = {
    linux = lib.optionalAttrs hostPlatform.isLinux {
      x86 = lib.optionalAttrs hostPlatform.isx86_64 {
        native = baseJobs;
        musl =
          {
            node =
              let
                muslProject = nodeProject.projectCross.musl64;
              in
              {
                cardano-node-linux = muslProject.release;
                internal = { inherit (muslProject) roots; };
              };
          };
        windows =
          {
            node =
              let windowsProject = nodeProject.projectCross.mingwW64;
              in
              {
                inherit (windowsProject) checks benchmarks;
                cardano-node-win64 = windowsProject.release;
                internal = { inherit (windowsProject) roots; };
              };
          };
      };
      arm = lib.optionalAttrs hostPlatform.isAarch64 {
        world = {
          inherit (project) exes;
          internal = {
            inherit (project) roots plan-nix;
          };
        };
        node = {
          inherit (nodeProject) exes;
          internal = {
            inherit (nodeProject) roots plan-nix;
          };
        };
        ogmios = {
          inherit (ogmiosProject) exes;
          internal = {
            inherit (ogmiosProject) roots plan-nix;
          };
        };
      };
    };
    macos = lib.optionalAttrs hostPlatform.isDarwin {
      x86 = lib.optionalAttrs hostPlatform.isx86_64 (baseJobs // {
        cardano-node-macos = nodeProject.release;
      });
      arm = lib.optionalAttrs hostPlatform.isAarch64 (baseJobs // {
        cardano-node-macos = nodeProject.release;
      });
    };
  };
  nonRequiredPaths = map lib.hasPrefix [ ];
  required = mkHydraRequiredJob nonRequiredPaths jobs;
in
jobs // {
  inherit required;
}
