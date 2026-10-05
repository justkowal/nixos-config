{ pkgs, ... }:

let
  nixBuilder = pkgs.writeShellApplication {
    name = "nix-builder";
    runtimeInputs = with pkgs; [ coreutils gnused gawk netcat curl openssh wakeonlan iputils nh ];
    checkPhase = "";
    text = builtins.readFile ../hosts/desktop/scripts/nix-builder-prompt.sh;
  };

  nixCachePush = pkgs.writeShellScriptBin "nix-cache-push" ''
    set -euo pipefail
    TARGET="ssh://justkowal@nixos-rpi4.lab"
    if [ "$#" -eq 0 ]; then
      echo "Pushing current system to Pi cache (nixos-rpi4.lab)..."
      exec nix copy --to "$TARGET" /run/current-system
    else
      echo "Pushing store paths to Pi cache (nixos-rpi4.lab)..."
      exec nix copy --to "$TARGET" "$@"
    fi
  '';
in
{
  # Nushell and bash available system-wide
  environment.shells = with pkgs; [ nushell bashInteractive ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    silent = true;
    direnvrcExtra = ''
      # Route nix-direnv through nix-builder for interactive wake prompts
      _nix() {
        if command -v nix-builder >/dev/null 2>&1; then
          nix-builder ''${_nix_direnv_nix} --no-warn-dirty --extra-experimental-features "nix-command flakes" "$@"
        else
          ''${_nix_direnv_nix} --no-warn-dirty --extra-experimental-features "nix-command flakes" "$@"
        fi
      }
    '';
  };

  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      zlib
      stdenv.cc.cc
      openssl
      icu
      fuse3
      glibc
      libx11
      libxcursor
      libxrandr
      libxi
      libglvnd
    ];
  };

  environment.systemPackages = with pkgs; [
    coreutils
    uutils-coreutils-noprefix
    git
    git-lfs
    tree
    ripgrep
    unzip
    zip
    lsof
    dnsutils
    traceroute
    iotop
    ncdu
    bat
    eza
    fastfetch
    nixBuilder
    nixCachePush
  ];

  environment.sessionVariables = {
    PLAYWRIGHT_DRIVER_DOWNLOAD_HOST = "";
    PLAYWRIGHT_DRIVER_PATH = "${pkgs.playwright-driver}";
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  };

  environment.interactiveShellInit = ''
    alias fallback-bash="exec ${pkgs.bashInteractive}/bin/bash"
    alias discord="vesktop"
    alias rebuild="nix-builder"
    alias nix-shell="nix-builder nix-shell"
    alias dev="nix-builder nix develop"
    alias nd="nix-builder nix develop"

    nix() {
      case "''${1:-}" in
        develop|shell|build)
          command nix-builder nix "$@"
          ;;
        *)
          command nix "$@"
          ;;
      esac
    }

    # ThinkPad Dot completion alert for commands running longer than 15s
    if [ -n "''${PS1:-}" ]; then
      __thinkdot_preexec() {
        __THINKDOT_CMD_START=$SECONDS
      }
      __thinkdot_precmd() {
        if [ -n "''${__THINKDOT_CMD_START:-}" ]; then
          local elapsed=$((SECONDS - __THINKDOT_CMD_START))
          unset __THINKDOT_CMD_START
          if [ "$elapsed" -ge 15 ]; then
            command -v thinkdot >/dev/null 2>&1 && thinkdot burst 3 &
          fi
        fi
      }
      trap '__thinkdot_preexec' DEBUG
      PROMPT_COMMAND="''${PROMPT_COMMAND:+$PROMPT_COMMAND; }__thinkdot_precmd"
    fi
  '';
}
