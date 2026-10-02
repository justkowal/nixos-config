{ pkgs, ... }:

{
  programs.nushell = {
    enable = true;
    extraConfig = ''
      $env.TZ = "Europe/Warsaw"
      $env.PLAYWRIGHT_DRIVER_DOWNLOAD_HOST = ""
      $env.PLAYWRIGHT_DRIVER_PATH = "${pkgs.playwright-driver}"
      $env.PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}"
      $env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1"

      $env.config = {
        show_banner: false
        completions: {
          case_sensitive: false
          quick: true
          partial: true
          algorithm: "fuzzy"
          external: {
            enable: true
            max_results: 100
            completer: {|spans|
              carapace $spans.0 nushell ...$spans | from json
            }
          }
        }
        hooks: {
          pre_execution: [{ ||
            $env.THINKDOT_CMD_START = (date now)
          }]
          pre_prompt: [{ ||
            if ($env.THINKDOT_CMD_START? != null) {
              let elapsed = ((date now) - $env.THINKDOT_CMD_START)
              $env.THINKDOT_CMD_START = null
              if ($elapsed >= 15sec) {
                if (which thinkdot | is-not-empty) {
                  ^thinkdot burst 3 out+err> /dev/null &
                }
              }
            }
          }]
        }
      }

      alias discord = vesktop
    '';
  };

  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
  };

  programs.carapace = {
    enable = true;
    enableNushellIntegration = true;
  };

  programs.fzf = {
    enable = true;
    enableNushellIntegration = false;
  };

  programs.git = {
    enable = true;
    userName = "justkowal";
    userEmail = "justkowal@users.noreply.github.com";
    extraConfig = {
      init.defaultBranch = "main";
    };
  };

  xdg.configFile."macchina/macchina.toml".text = ''
    theme = "nixos"
  '';

  xdg.configFile."macchina/themes/nixos.toml".text = ''
    spacing = 2
    padding = 0
    hide_ascii = false
    prefer_small_ascii = false

    [custom_ascii]
    path = "/home/justkowal/.config/macchina/nixos_logo.txt"
    color = "Cyan"
  '';

  xdg.configFile."macchina/nixos_logo.txt".text = ''
              ▗▄▄▄       ▗▄▄▄▄    ▄▄▄▖
              ▜███▙       ▜███▙  ▟███▛
               ▜███▙       ▜███▙▟███▛
                ▜███▙       ▜██████▛
         ▟█████████████████▙ ▜████▛     ▟▙
        ▟███████████████████▙ ▜███▙    ▟██▙
               ▄▄▄▄▖           ▜███▙  ▟███▛
              ▟███▛             ▜██▛ ▟███▛
             ▟███▛               ▜▛ ▟███▛
    ▟███████████▛                  ▟██████████▙
    ▜██████████▛                  ▟███████████▛
          ▟███▛ ▟▙               ▟███▛
         ▟███▛ ▟██▙             ▟███▛
        ▟███▛  ▜███▙           ▝▀▀▀▀
        ▜██▛    ▜███▙ ▜██████████████████▛
         ▜▛     ▟████▙ ▜████████████████▛
               ▟██████▙         ▜███▙
              ▟███▛▜███▙         ▜███▙
             ▟███▛  ▜███▙         ▜███▙
             ▝▀▀▀    ▀▀▀▀▘         ▀▀▀▘
  '';
}
