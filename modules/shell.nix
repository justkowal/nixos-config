{ pkgs, ... }:

{
  # Nushell and bash available system-wide
  environment.shells = with pkgs; [ nushell bashInteractive ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    silent = true;
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
    uutils-coreutils-noprefix
    git
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
