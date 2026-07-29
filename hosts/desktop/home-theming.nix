{ config, pkgs, lib, ... }: {

  # ═══════════════════════════════════════════════════════════════════════
  # Matugen Material You Dynamic Theming Templates
  # All templates are processed by matugen to generate theme files for
  # each application from wallpaper-extracted Material Design 3 colors.
  # ═══════════════════════════════════════════════════════════════════════

  # --- Starship Prompt ---
  xdg.configFile."matugen/templates/starship.toml".text = ''
    "$schema" = 'https://starship.rs/config-schema.json'

    format = """
    []({{ colors.primary.default.hex }})\
    $os\
    $username\
    [](bg:{{ colors.secondary.default.hex }} fg:{{ colors.primary.default.hex }})\
    $directory\
    [](bg:{{ colors.tertiary.default.hex }} fg:{{ colors.secondary.default.hex }})\
    $git_branch\
    $git_status\
    [](bg:{{ colors.primary_container.default.hex }} fg:{{ colors.tertiary.default.hex }})\
    $c\
    $rust\
    $golang\
    $nodejs\
    $bun\
    $php\
    $java\
    $kotlin\
    $haskell\
    $python\
    [](bg:{{ colors.secondary_container.default.hex }} fg:{{ colors.primary_container.default.hex }})\
    $conda\
    [](bg:{{ colors.tertiary_container.default.hex }} fg:{{ colors.secondary_container.default.hex }})\
    $time\
    [ ](fg:{{ colors.tertiary_container.default.hex }})\
    $cmd_duration\
    $line_break\
    $character"""

    [os]
    disabled = false
    style = "bg:{{ colors.primary.default.hex }} fg:{{ colors.on_primary.default.hex }}"

    [os.symbols]
    NixOS = " "
    Windows = " "
    Ubuntu = "󰕈 "
    SUSE = " "
    Raspbian = "󰐿 "
    Mint = "󰣭 "
    Macos = "󰀵 "
    Manjaro = " "
    Linux = "󰌽 "
    Gentoo = "󰣨 "
    Fedora = "󰣛 "
    Alpine = " "
    Amazon = " "
    Android = " "
    AOSC = " "
    Arch = "󰣇 "
    Artix = "󰣇 "
    CentOS = " "
    Debian = "󰣚 "
    Redhat = "󱄛 "
    RedHatEnterprise = "󱄛 "

    [username]
    show_always = true
    style_user = "bg:{{ colors.primary.default.hex }} fg:{{ colors.on_primary.default.hex }}"
    style_root = "bg:{{ colors.primary.default.hex }} fg:{{ colors.on_primary.default.hex }}"
    format = '[ $user]($style)'

    [directory]
    style = "bg:{{ colors.secondary.default.hex }} fg:{{ colors.on_secondary.default.hex }}"
    format = "[ $path ]($style)"
    truncation_length = 3
    truncation_symbol = "…/"

    [directory.substitutions]
    "Documents" = "󰈙 "
    "Downloads" = " "
    "Music" = "󰝚 "
    "Pictures" = " "
    "Developer" = "󰲋 "

    [git_branch]
    symbol = ""
    style = "bg:{{ colors.tertiary.default.hex }} fg:{{ colors.on_tertiary.default.hex }}"
    format = '[[ $symbol $branch ](fg:{{ colors.on_tertiary.default.hex }} bg:{{ colors.tertiary.default.hex }})]($style)'

    [git_status]
    style = "bg:{{ colors.tertiary.default.hex }} fg:{{ colors.on_tertiary.default.hex }}"
    format = '[[($all_status$ahead_behind )](fg:{{ colors.on_tertiary.default.hex }} bg:{{ colors.tertiary.default.hex }})]($style)'

    [nodejs]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [bun]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [c]
    symbol = " "
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [rust]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [golang]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [php]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [java]
    symbol = " "
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [kotlin]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [haskell]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [python]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version)(\\($virtualenv\\)) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [docker_context]
    symbol = ""
    style = "bg:{{ colors.secondary_container.default.hex }} fg:{{ colors.on_secondary_container.default.hex }}"
    format = '[[ $symbol( $context) ](fg:{{ colors.on_secondary_container.default.hex }} bg:{{ colors.secondary_container.default.hex }})]($style)'

    [conda]
    symbol = "  "
    style = "bg:{{ colors.secondary_container.default.hex }} fg:{{ colors.on_secondary_container.default.hex }}"
    format = '[$symbol$environment ]($style)'
    ignore_base = false

    [time]
    disabled = false
    time_format = "%R"
    style = "bg:{{ colors.tertiary_container.default.hex }} fg:{{ colors.on_tertiary_container.default.hex }}"
    format = '[[  $time ](fg:{{ colors.on_tertiary_container.default.hex }} bg:{{ colors.tertiary_container.default.hex }})]($style)'

    [line_break]
    disabled = true

    [character]
    disabled = false
    success_symbol = '[❯](bold fg:{{ colors.primary.default.hex }})'
    error_symbol = '[❯](bold fg:{{ colors.error.default.hex }})'
    vimcmd_symbol = '[❮](bold fg:{{ colors.primary.default.hex }})'
    vimcmd_replace_one_symbol = '[❮](bold fg:{{ colors.tertiary_container.default.hex }})'
    vimcmd_replace_symbol = '[❮](bold fg:{{ colors.tertiary_container.default.hex }})'
    vimcmd_visual_symbol = '[❮](bold fg:{{ colors.secondary.default.hex }})'

    [cmd_duration]
    show_milliseconds = true
    format = " in $duration "
    style = "fg:{{ colors.on_background.default.hex }}"
    disabled = false
    show_notifications = true
    min_time_to_notify = 45000
  '';

  # --- VS Code Theme ---
  xdg.configFile."matugen/templates/vscode-theme.json".text = ''
    {
      "name": "Matugen",
      "type": "dark",
      "colors": {
        "activityBar.background": "{{ colors.surface.default.hex }}",
        "activityBar.foreground": "{{ colors.on_surface.default.hex }}",
        "activityBarBadge.background": "{{ colors.primary.default.hex }}",
        "activityBarBadge.foreground": "{{ colors.on_primary.default.hex }}",
        "editor.background": "{{ colors.background.default.hex }}",
        "editor.foreground": "{{ colors.on_background.default.hex }}",
        "editor.selectionBackground": "{{ colors.primary.default.hex }}",
        "editor.inactiveSelectionBackground": "{{ colors.surface_variant.default.hex }}",
        "editor.lineHighlightBackground": "{{ colors.surface_variant.default.hex }}",
        "editorCursor.foreground": "{{ colors.primary.default.hex }}",
        "editorIndentGuide.background1": "{{ colors.outline.default.hex }}",
        "editorIndentGuide.activeBackground1": "{{ colors.primary.default.hex }}",
        "editorLineNumber.foreground": "{{ colors.on_surface_variant.default.hex }}",
        "editorLineNumber.activeForeground": "{{ colors.on_background.default.hex }}",
        "editorWidget.background": "{{ colors.surface.default.hex }}",
        "editorWidget.foreground": "{{ colors.on_surface.default.hex }}",
        "focusBorder": "{{ colors.primary.default.hex }}",
        "input.background": "{{ colors.surface.default.hex }}",
        "input.foreground": "{{ colors.on_surface.default.hex }}",
        "input.border": "{{ colors.outline.default.hex }}",
        "list.activeSelectionBackground": "{{ colors.primary.default.hex }}",
        "list.activeSelectionForeground": "{{ colors.on_primary.default.hex }}",
        "list.hoverBackground": "{{ colors.surface_variant.default.hex }}",
        "list.inactiveSelectionBackground": "{{ colors.surface_variant.default.hex }}",
        "menu.background": "{{ colors.surface.default.hex }}",
        "menu.foreground": "{{ colors.on_surface.default.hex }}",
        "panel.background": "{{ colors.surface.default.hex }}",
        "panel.border": "{{ colors.outline.default.hex }}",
        "peekView.border": "{{ colors.primary.default.hex }}",
        "peekViewEditor.background": "{{ colors.background.default.hex }}",
        "peekViewResult.background": "{{ colors.surface.default.hex }}",
        "statusBar.background": "{{ colors.background.default.hex }}",
        "statusBar.foreground": "{{ colors.on_background.default.hex }}",
        "statusBar.debuggingBackground": "{{ colors.tertiary.default.hex }}",
        "sideBar.background": "{{ colors.background.default.hex }}",
        "sideBar.foreground": "{{ colors.on_background.default.hex }}",
        "sideBarSectionHeader.background": "{{ colors.surface.default.hex }}",
        "sideBarSectionHeader.foreground": "{{ colors.on_surface.default.hex }}",
        "tab.activeBackground": "{{ colors.surface.default.hex }}",
        "tab.activeForeground": "{{ colors.on_surface.default.hex }}",
        "tab.border": "{{ colors.outline.default.hex }}",
        "tab.inactiveBackground": "{{ colors.background.default.hex }}",
        "terminal.background": "{{ colors.background.default.hex }}",
        "terminal.foreground": "{{ colors.on_background.default.hex }}",
        "terminalCursor.foreground": "{{ colors.primary.default.hex }}",
        "titleBar.activeBackground": "{{ colors.background.default.hex }}",
        "titleBar.activeForeground": "{{ colors.on_background.default.hex }}",
        "titleBar.border": "{{ colors.outline.default.hex }}",
        "window.activeBorder": "{{ colors.primary.default.hex }}",
        "window.inactiveBorder": "{{ colors.outline.default.hex }}"
      },
      "tokenColors": [
        {
          "scope": ["comment", "punctuation.definition.comment"],
          "settings": {
            "foreground": "{{ colors.on_surface_variant.default.hex }}"
          }
        },
        {
          "scope": ["string", "constant.other.symbol"],
          "settings": {
            "foreground": "{{ colors.secondary.default.hex }}"
          }
        },
        {
          "scope": ["constant.numeric", "constant.language"],
          "settings": {
            "foreground": "{{ colors.tertiary.default.hex }}"
          }
        },
        {
          "scope": ["keyword", "storage"],
          "settings": {
            "foreground": "{{ colors.primary.default.hex }}"
          }
        },
        {
          "scope": ["entity.name.function", "support.function"],
          "settings": {
            "foreground": "{{ colors.primary_container.default.hex }}"
          }
        }
      ]
    }
  '';

  # --- Firefox Material Blue CSS ---
  xdg.configFile."matugen/templates/theme-material-blue.css".text = ''
    @media -moz-pref("userChrome.theme-material") {
      :root {
        --md-sys-color-primary: {{ colors.primary.default.hex }};
        --md-sys-color-surface-tint: {{ colors.surface_tint.default.hex }};
        --md-sys-color-on-primary: {{ colors.on_primary.default.hex }};
        --md-sys-color-primary-container: {{ colors.primary_container.default.hex }};
        --md-sys-color-on-primary-container: {{ colors.on_primary_container.default.hex }};
        --md-sys-color-secondary: {{ colors.secondary.default.hex }};
        --md-sys-color-on-secondary: {{ colors.on_secondary.default.hex }};
        --md-sys-color-secondary-container: {{ colors.secondary_container.default.hex }};
        --md-sys-color-on-secondary-container: {{ colors.on_secondary_container.default.hex }};
        --md-sys-color-tertiary: {{ colors.tertiary.default.hex }};
        --md-sys-color-on-tertiary: {{ colors.on_tertiary.default.hex }};
        --md-sys-color-tertiary-container: {{ colors.tertiary_container.default.hex }};
        --md-sys-color-on-tertiary-container: {{ colors.on_tertiary_container.default.hex }};
        --md-sys-color-error: {{ colors.error.default.hex }};
        --md-sys-color-on-error: {{ colors.on_error.default.hex }};
        --md-sys-color-error-container: {{ colors.error_container.default.hex }};
        --md-sys-color-on-error-container: {{ colors.on_error_container.default.hex }};
        --md-sys-color-background: {{ colors.background.default.hex }};
        --md-sys-color-on-background: {{ colors.on_background.default.hex }};
        --md-sys-color-surface: {{ colors.surface.default.hex }};
        --md-sys-color-on-surface: {{ colors.on_surface.default.hex }};
        --md-sys-color-surface-variant: {{ colors.surface_variant.default.hex }};
        --md-sys-color-on-surface-variant: {{ colors.on_surface_variant.default.hex }};
        --md-sys-color-outline: {{ colors.outline.default.hex }};
        --md-sys-color-outline-variant: {{ colors.outline_variant.default.hex }};
        --md-sys-color-shadow: {{ colors.shadow.default.hex }};
        --md-sys-color-scrim: {{ colors.scrim.default.hex }};
        --md-sys-color-inverse-surface: {{ colors.inverse_surface.default.hex }};
        --md-sys-color-inverse-on-surface: {{ colors.inverse_on_surface.default.hex }};
        --md-sys-color-inverse-primary: {{ colors.inverse_primary.default.hex }};
        --md-sys-color-primary-fixed: {{ colors.primary_fixed.default.hex }};
        --md-sys-color-on-primary-fixed: {{ colors.on_primary_fixed.default.hex }};
        --md-sys-color-primary-fixed-dim: {{ colors.primary_fixed_dim.default.hex }};
        --md-sys-color-on-primary-fixed-variant: {{ colors.on_primary_fixed_variant.default.hex }};
        --md-sys-color-secondary-fixed: {{ colors.secondary_fixed.default.hex }};
        --md-sys-color-on-secondary-fixed: {{ colors.on_secondary_fixed.default.hex }};
        --md-sys-color-secondary-fixed-dim: {{ colors.secondary_fixed_dim.default.hex }};
        --md-sys-color-on-secondary-fixed-variant: {{ colors.on_secondary_fixed_variant.default.hex }};
        --md-sys-color-tertiary-fixed: {{ colors.tertiary_fixed.default.hex }};
        --md-sys-color-on-tertiary-fixed: {{ colors.on_tertiary_fixed.default.hex }};
        --md-sys-color-tertiary-fixed-dim: {{ colors.tertiary_fixed_dim.default.hex }};
        --md-sys-color-on-tertiary-fixed-variant: {{ colors.on_tertiary_fixed_variant.default.hex }};
        --md-sys-color-surface-dim: {{ colors.surface_dim.default.hex }};
        --md-sys-color-surface-bright: {{ colors.surface_bright.default.hex }};
        --md-sys-color-surface-container-lowest: {{ colors.surface_container_lowest.default.hex }};
        --md-sys-color-surface-container-low: {{ colors.surface_container_low.default.hex }};
        --md-sys-color-surface-container: {{ colors.surface_container.default.hex }};
        --md-sys-color-surface-container-high: {{ colors.surface_container_high.default.hex }};
        --md-sys-color-surface-container-highest: {{ colors.surface_container_highest.default.hex }};
      }

      @media (prefers-color-scheme: dark) {
        :root {
          --md-sys-color-primary: {{ colors.primary.default.hex }};
          --md-sys-color-surface-tint: {{ colors.surface_tint.default.hex }};
          --md-sys-color-on-primary: {{ colors.on_primary.default.hex }};
          --md-sys-color-primary-container: {{ colors.primary_container.default.hex }};
          --md-sys-color-on-primary-container: {{ colors.on_primary_container.default.hex }};
          --md-sys-color-secondary: {{ colors.secondary.default.hex }};
          --md-sys-color-on-secondary: {{ colors.on_secondary.default.hex }};
          --md-sys-color-secondary-container: {{ colors.secondary_container.default.hex }};
          --md-sys-color-on-secondary-container: {{ colors.on_secondary_container.default.hex }};
          --md-sys-color-tertiary: {{ colors.tertiary.default.hex }};
          --md-sys-color-on-tertiary: {{ colors.on_tertiary.default.hex }};
          --md-sys-color-tertiary-container: {{ colors.tertiary_container.default.hex }};
          --md-sys-color-on-tertiary-container: {{ colors.on_tertiary_container.default.hex }};
          --md-sys-color-error: {{ colors.error.default.hex }};
          --md-sys-color-on-error: {{ colors.on_error.default.hex }};
          --md-sys-color-error-container: {{ colors.error_container.default.hex }};
          --md-sys-color-on-error-container: {{ colors.on_error_container.default.hex }};
          --md-sys-color-background: {{ colors.background.default.hex }};
          --md-sys-color-on-background: {{ colors.on_background.default.hex }};
          --md-sys-color-surface: {{ colors.surface.default.hex }};
          --md-sys-color-on-surface: {{ colors.on_surface.default.hex }};
          --md-sys-color-surface-variant: {{ colors.surface_variant.default.hex }};
          --md-sys-color-on-surface-variant: {{ colors.on_surface_variant.default.hex }};
          --md-sys-color-outline: {{ colors.outline.default.hex }};
          --md-sys-color-outline-variant: {{ colors.outline_variant.default.hex }};
          --md-sys-color-shadow: {{ colors.shadow.default.hex }};
          --md-sys-color-scrim: {{ colors.scrim.default.hex }};
          --md-sys-color-inverse-surface: {{ colors.inverse_surface.default.hex }};
          --md-sys-color-inverse-on-surface: {{ colors.inverse_on_surface.default.hex }};
          --md-sys-color-inverse-primary: {{ colors.inverse_primary.default.hex }};
          --md-sys-color-primary-fixed: {{ colors.primary_fixed.default.hex }};
          --md-sys-color-on-primary-fixed: {{ colors.on_primary_fixed.default.hex }};
          --md-sys-color-primary-fixed-dim: {{ colors.primary_fixed_dim.default.hex }};
          --md-sys-color-on-primary-fixed-variant: {{ colors.on_primary_fixed_variant.default.hex }};
          --md-sys-color-secondary-fixed: {{ colors.secondary_fixed.default.hex }};
          --md-sys-color-on-secondary-fixed: {{ colors.on_secondary_fixed.default.hex }};
          --md-sys-color-secondary-fixed-dim: {{ colors.secondary_fixed_dim.default.hex }};
          --md-sys-color-on-secondary-fixed-variant: {{ colors.on_secondary_fixed_variant.default.hex }};
          --md-sys-color-tertiary-fixed: {{ colors.tertiary_fixed.default.hex }};
          --md-sys-color-on-tertiary-fixed: {{ colors.on_tertiary_fixed.default.hex }};
          --md-sys-color-tertiary-fixed-dim: {{ colors.tertiary_fixed_dim.default.hex }};
          --md-sys-color-on-tertiary-fixed-variant: {{ colors.on_tertiary_fixed_variant.default.hex }};
          --md-sys-color-surface-dim: {{ colors.surface_dim.default.hex }};
          --md-sys-color-surface-bright: {{ colors.surface_bright.default.hex }};
          --md-sys-color-surface-container-lowest: {{ colors.surface_container_lowest.default.hex }};
          --md-sys-color-surface-container-low: {{ colors.surface_container_low.default.hex }};
          --md-sys-color-surface-container: {{ colors.surface_container.default.hex }};
          --md-sys-color-surface-container-high: {{ colors.surface_container_high.default.hex }};
          --md-sys-color-surface-container-highest: {{ colors.surface_container_highest.default.hex }};
        }
      }
    }
  '';

  # --- Waybar Colors ---
  xdg.configFile."matugen/templates/waybar-colors.css".text = ''
    @define-color background {{ colors.background.default.hex }};
    @define-color on_background {{ colors.on_background.default.hex }};
    @define-color surface {{ colors.surface.default.hex }};
    @define-color surface_variant {{ colors.surface_variant.default.hex }};
    @define-color on_surface {{ colors.on_surface.default.hex }};
    @define-color on_surface_variant {{ colors.on_surface_variant.default.hex }};
    @define-color primary {{ colors.primary.default.hex }};
    @define-color primary_container {{ colors.primary_container.default.hex }};
    @define-color on_primary {{ colors.on_primary.default.hex }};
    @define-color secondary {{ colors.secondary.default.hex }};
    @define-color tertiary {{ colors.tertiary.default.hex }};
    @define-color outline {{ colors.outline.default.hex }};
  '';

  # --- Hyprland Colors ---
  xdg.configFile."matugen/templates/hyprland-colors.conf".text = ''
    $background = rgba({{ colors.background.default.hex_stripped }}ff)
    $background_transparent = rgba({{ colors.background.default.hex_stripped }}cc)
    $surface = rgba({{ colors.surface.default.hex_stripped }}ff)
    $surface_variant = rgba({{ colors.surface_variant.default.hex_stripped }}ff)
    $on_surface = rgba({{ colors.on_surface.default.hex_stripped }}ff)
    $primary = rgba({{ colors.primary.default.hex_stripped }}ff)
    $secondary = rgba({{ colors.secondary.default.hex_stripped }}ff)
    $tertiary = rgba({{ colors.tertiary.default.hex_stripped }}ff)
    $outline = rgba({{ colors.outline.default.hex_stripped }}ff)
  '';

  # --- Kitty Colors ---
  xdg.configFile."matugen/templates/kitty-colors.conf".text = ''
    # Matugen generated colors for Kitty
    background {{ colors.background.default.hex }}
    foreground {{ colors.on_background.default.hex }}
    cursor {{ colors.primary.default.hex }}
    cursor_text_color {{ colors.on_primary.default.hex }}
    selection_background {{ colors.primary_container.default.hex }}
    selection_foreground {{ colors.on_primary_container.default.hex }}

    # black
    color0 {{ colors.surface.default.hex }}
    color8 {{ colors.surface_variant.default.hex }}

    # red
    color1 {{ colors.error.default.hex }}
    color9 {{ colors.error.default.hex }}

    # green
    color2 {{ colors.primary.default.hex }}
    color10 {{ colors.primary.default.hex }}

    # yellow
    color3 {{ colors.secondary.default.hex }}
    color11 {{ colors.secondary.default.hex }}

    # blue
    color4 {{ colors.tertiary.default.hex }}
    color12 {{ colors.tertiary.default.hex }}

    # magenta
    color5 {{ colors.primary_container.default.hex }}
    color13 {{ colors.primary_container.default.hex }}

    # cyan
    color6 {{ colors.outline.default.hex }}
    color14 {{ colors.outline.default.hex }}

    # white
    color7 {{ colors.on_surface.default.hex }}
    color15 {{ colors.on_surface_variant.default.hex }}
  '';

  # --- Rofi Colors ---
  xdg.configFile."matugen/templates/rofi-colors.rasi".text = ''
    * {
        bg-col: {{ colors.background.default.hex }};
        border-col: {{ colors.outline.default.hex }};
        selected-col: {{ colors.surface_variant.default.hex }};
        text-col: {{ colors.on_background.default.hex }};
        accent-col: {{ colors.primary.default.hex }};
    }
  '';

  # --- SwayNC Colors ---
  xdg.configFile."matugen/templates/swaync-colors.css".text = ''
    @define-color background {{ colors.background.default.hex }};
    @define-color on_background {{ colors.on_background.default.hex }};
    @define-color surface {{ colors.surface.default.hex }};
    @define-color surface_variant {{ colors.surface_variant.default.hex }};
    @define-color on_surface {{ colors.on_surface.default.hex }};
    @define-color on_surface_variant {{ colors.on_surface_variant.default.hex }};
    @define-color primary {{ colors.primary.default.hex }};
    @define-color primary_container {{ colors.primary_container.default.hex }};
    @define-color on_primary {{ colors.on_primary.default.hex }};
    @define-color secondary {{ colors.secondary.default.hex }};
    @define-color tertiary {{ colors.tertiary.default.hex }};
    @define-color outline {{ colors.outline.default.hex }};
  '';

  # --- VS Code raw color data ---
  xdg.configFile."matugen/templates/vscode-colors".text = ''
    {{ colors.background.default.hex }}
    {{ colors.on_surface.default.hex | saturate: 70.0, hsl }}
    {{ colors.secondary.default.hex | saturate: 20.0, hsl }}
    {{ colors.tertiary.default.hex | saturate: 15.0, hsl }}
    {{ colors.primary.default.hex }}
    {{ colors.tertiary.default.hex }}
    {{ colors.secondary_container.default.hex | saturate: 20.0, hsl }}
    {{ colors.on_surface_variant.default.hex }}
    {{ colors.surface_variant.default.hex }}
    {{ colors.surface_tint.default.hex | saturate: 15.0, hsl }}
    {{ colors.secondary.default.hex | auto_lightness: 10.0 | saturate: 20.0, hsl }}
    {{ colors.tertiary.default.hex | auto_lightness: 10.0 | saturate: 15.0, hsl }}
    {{ colors.primary.default.hex | auto_lightness: 10.0 }}
    {{ colors.tertiary.default.hex | auto_lightness: 10.0 }}
    {{ colors.primary_container.default.hex | saturate: 10.0, hsl }}
    {{ colors.on_background.default.hex }}
  '';

  # --- VS Code JSON color data ---
  xdg.configFile."matugen/templates/vscode-colors.json".text = ''
    {
      "checksum": ":)",
      "wallpaper": "{{ image }}",
      "alpha": "100",
      "special": {
        "background": "{{ colors.background.default.hex }}",
        "foreground": "{{ colors.on_background.default.hex }}",
        "cursor": "{{ colors.primary.default.hex }}"
      },
      "colors": {
        "color0": "{{ colors.background.default.hex }}",
        "color1": "{{ colors.on_surface.default.hex | saturate: 70.0, hsl }}",
        "color2": "{{ colors.secondary.default.hex | saturate: 20.0, hsl }}",
        "color3": "{{ colors.tertiary.default.hex | saturate: 15.0, hsl }}",
        "color4": "{{ colors.primary.default.hex }}",
        "color5": "{{ colors.tertiary.default.hex }}",
        "color6": "{{ colors.secondary_container.default.hex | saturate: 20.0, hsl }}",
        "color7": "{{ colors.on_surface_variant.default.hex }}",
        "color8": "{{ colors.surface_variant.default.hex }}",
        "color9": "{{ colors.surface_tint.default.hex | saturate: 15.0, hsl }}",
        "color10": "{{ colors.secondary.default.hex | auto_lightness: 10.0 | saturate: 20.0, hsl }}",
        "color11": "{{ colors.tertiary.default.hex | auto_lightness: 10.0 | saturate: 15.0, hsl }}",
        "color12": "{{ colors.primary.default.hex | auto_lightness: 10.0 }}",
        "color13": "{{ colors.tertiary.default.hex | auto_lightness: 10.0 }}",
        "color14": "{{ colors.primary_container.default.hex | saturate: 10.0, hsl }}",
        "color15": "{{ colors.on_background.default.hex }}"
      }
    }
  '';

  # --- GTK3 Colors ---
  xdg.configFile."matugen/templates/gtk3.css".text = ''
    /* GTK3/GTK4 standard colors */
    @define-color theme_bg_color {{ colors.background.default.hex }};
    @define-color theme_fg_color {{ colors.on_background.default.hex }};
    @define-color theme_base_color {{ colors.surface.default.hex }};
    @define-color theme_text_color {{ colors.on_surface.default.hex }};
    @define-color theme_selected_bg_color {{ colors.primary.default.hex }};
    @define-color theme_selected_fg_color {{ colors.on_primary.default.hex }};
    @define-color tooltip_bg_color {{ colors.surface_variant.default.hex }};
    @define-color tooltip_fg_color {{ colors.on_surface_variant.default.hex }};

    /* Libadwaita / GTK4 specific colors */
    @define-color accent_color {{ colors.primary.default.hex }};
    @define-color accent_bg_color {{ colors.primary.default.hex }};
    @define-color accent_fg_color {{ colors.on_primary.default.hex }};
    @define-color window_bg_color {{ colors.background.default.hex }};
    @define-color window_fg_color {{ colors.on_background.default.hex }};
    @define-color view_bg_color {{ colors.surface.default.hex }};
    @define-color view_fg_color {{ colors.on_surface.default.hex }};
    @define-color headerbar_bg_color {{ colors.background.default.hex }};
    @define-color headerbar_fg_color {{ colors.on_background.default.hex }};
    @define-color headerbar_border_color {{ colors.outline.default.hex }};
    @define-color card_bg_color {{ colors.surface_variant.default.hex }};
    @define-color card_fg_color {{ colors.on_surface_variant.default.hex }};
    @define-color dialog_bg_color {{ colors.background.default.hex }};
    @define-color dialog_fg_color {{ colors.on_background.default.hex }};
    @define-color popover_bg_color {{ colors.surface_variant.default.hex }};
    @define-color popover_fg_color {{ colors.on_surface_variant.default.hex }};
  '';

  # --- GTK4 Colors ---
  xdg.configFile."matugen/templates/gtk4.css".text = ''
    /* GTK3/GTK4 standard colors */
    @define-color theme_bg_color {{ colors.background.default.hex }};
    @define-color theme_fg_color {{ colors.on_background.default.hex }};
    @define-color theme_base_color {{ colors.surface.default.hex }};
    @define-color theme_text_color {{ colors.on_surface.default.hex }};
    @define-color theme_selected_bg_color {{ colors.primary.default.hex }};
    @define-color theme_selected_fg_color {{ colors.on_primary.default.hex }};
    @define-color tooltip_bg_color {{ colors.surface_variant.default.hex }};
    @define-color tooltip_fg_color {{ colors.on_surface_variant.default.hex }};

    /* Libadwaita / GTK4 specific colors */
    @define-color accent_color {{ colors.primary.default.hex }};
    @define-color accent_bg_color {{ colors.primary.default.hex }};
    @define-color accent_fg_color {{ colors.on_primary.default.hex }};
    @define-color window_bg_color {{ colors.background.default.hex }};
    @define-color window_fg_color {{ colors.on_background.default.hex }};
    @define-color view_bg_color {{ colors.surface.default.hex }};
    @define-color view_fg_color {{ colors.on_surface.default.hex }};
    @define-color headerbar_bg_color {{ colors.background.default.hex }};
    @define-color headerbar_fg_color {{ colors.on_background.default.hex }};
    @define-color headerbar_border_color {{ colors.outline.default.hex }};
    @define-color card_bg_color {{ colors.surface_variant.default.hex }};
    @define-color card_fg_color {{ colors.on_surface_variant.default.hex }};
    @define-color dialog_bg_color {{ colors.background.default.hex }};
    @define-color dialog_fg_color {{ colors.on_background.default.hex }};
    @define-color popover_bg_color {{ colors.surface_variant.default.hex }};
    @define-color popover_fg_color {{ colors.on_surface_variant.default.hex }};
  '';

  # --- Btop Theme ---
  xdg.configFile."matugen/templates/btop.theme".text = ''
    # btop Matugen dynamic colors

    theme[main_bg]=""
    theme[main_fg]="{{ colors.on_background.default.hex }}"
    theme[title]="{{ colors.primary.default.hex }}"
    theme[hi_fg]="{{ colors.secondary.default.hex }}"
    theme[selected_bg]="{{ colors.primary_container.default.hex }}"
    theme[selected_fg]="{{ colors.on_primary_container.default.hex }}"
    theme[inactive_fg]="{{ colors.outline.default.hex }}"
    theme[graph_text]="{{ colors.on_surface_variant.default.hex }}"
    theme[meter_bg]="{{ colors.surface_variant.default.hex }}"
    theme[proc_misc]="{{ colors.tertiary.default.hex }}"

    theme[cpu_box]="{{ colors.primary.default.hex }}"
    theme[mem_box]="{{ colors.secondary.default.hex }}"
    theme[net_box]="{{ colors.tertiary.default.hex }}"
    theme[proc_box]="{{ colors.outline.default.hex }}"
    theme[div_line]="{{ colors.outline_variant.default.hex }}"

    # Temperature graph
    theme[temp_start]="{{ colors.primary.default.hex }}"
    theme[temp_mid]="{{ colors.secondary.default.hex }}"
    theme[temp_end]="{{ colors.error.default.hex }}"

    # CPU graph
    theme[cpu_start]="{{ colors.primary.default.hex }}"
    theme[cpu_mid]="{{ colors.secondary.default.hex }}"
    theme[cpu_end]="{{ colors.tertiary.default.hex }}"

    # Memory/Disk meters
    theme[free_start]="{{ colors.primary.default.hex }}"
    theme[free_mid]="{{ colors.secondary.default.hex }}"
    theme[free_end]="{{ colors.tertiary.default.hex }}"
    theme[cached_start]="{{ colors.secondary.default.hex }}"
    theme[cached_mid]="{{ colors.tertiary.default.hex }}"
    theme[cached_end]="{{ colors.primary.default.hex }}"
    theme[available_start]="{{ colors.primary.default.hex }}"
    theme[available_mid]="{{ colors.secondary.default.hex }}"
    theme[available_end]="{{ colors.tertiary.default.hex }}"
    theme[used_start]="{{ colors.secondary.default.hex }}"
    theme[used_mid]="{{ colors.tertiary.default.hex }}"
    theme[used_end]="{{ colors.error.default.hex }}"

    # Network graphs
    theme[download_start]="{{ colors.primary.default.hex }}"
    theme[download_mid]="{{ colors.secondary.default.hex }}"
    theme[download_end]="{{ colors.tertiary.default.hex }}"
    theme[upload_start]="{{ colors.tertiary.default.hex }}"
    theme[upload_mid]="{{ colors.secondary.default.hex }}"
    theme[upload_end]="{{ colors.error.default.hex }}"

    # Process gradient
    theme[process_start]="{{ colors.primary.default.hex }}"
    theme[process_mid]="{{ colors.secondary.default.hex }}"
    theme[process_end]="{{ colors.tertiary.default.hex }}"
  '';

  # --- Steam CSS ---
  xdg.configFile."matugen/templates/steam.css".text = ''
    :root {
        --theme-color: "Matugen";
        --hue-rotate: 220deg;
        <* for name, value in colors *>
        --md-sys-color-{{name | replace: "_", "-" }}: {{value.default.rgb}};
        <* endfor *>
    }
  '';

  # --- KDE/Qt Color Scheme (for Dolphin and all KDE/Qt apps) ---
  xdg.configFile."matugen/templates/kde-colors.colors".text = ''
    [ColorEffects:Disabled]
    Color=56,56,56
    ColorAmount=0
    ColorEffect=0
    ContrastAmount=0.65
    ContrastEffect=1
    IntensityAmount=0.1
    IntensityEffect=2

    [ColorEffects:Inactive]
    ChangeSelectionColor=true
    Color=112,111,110
    ColorAmount=0.025
    ColorEffect=2
    ContrastAmount=0.1
    ContrastEffect=2
    Enable=false
    IntensityAmount=0
    IntensityEffect=0

    [Colors:Button]
    BackgroundAlternate={{ colors.surface_variant.default.red }},{{ colors.surface_variant.default.green }},{{ colors.surface_variant.default.blue }}
    BackgroundNormal={{ colors.surface.default.red }},{{ colors.surface.default.green }},{{ colors.surface.default.blue }}
    DecorationFocus={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    DecorationHover={{ colors.primary_container.default.red }},{{ colors.primary_container.default.green }},{{ colors.primary_container.default.blue }}
    ForegroundActive={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    ForegroundInactive={{ colors.outline.default.red }},{{ colors.outline.default.green }},{{ colors.outline.default.blue }}
    ForegroundLink={{ colors.tertiary.default.red }},{{ colors.tertiary.default.green }},{{ colors.tertiary.default.blue }}
    ForegroundNegative={{ colors.error.default.red }},{{ colors.error.default.green }},{{ colors.error.default.blue }}
    ForegroundNeutral={{ colors.secondary.default.red }},{{ colors.secondary.default.green }},{{ colors.secondary.default.blue }}
    ForegroundNormal={{ colors.on_surface.default.red }},{{ colors.on_surface.default.green }},{{ colors.on_surface.default.blue }}
    ForegroundPositive={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    ForegroundVisited={{ colors.tertiary_container.default.red }},{{ colors.tertiary_container.default.green }},{{ colors.tertiary_container.default.blue }}

    [Colors:Selection]
    BackgroundAlternate={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    BackgroundNormal={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    DecorationFocus={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    DecorationHover={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    ForegroundActive={{ colors.on_primary.default.red }},{{ colors.on_primary.default.green }},{{ colors.on_primary.default.blue }}
    ForegroundInactive={{ colors.on_primary.default.red }},{{ colors.on_primary.default.green }},{{ colors.on_primary.default.blue }}
    ForegroundLink={{ colors.on_primary.default.red }},{{ colors.on_primary.default.green }},{{ colors.on_primary.default.blue }}
    ForegroundNegative={{ colors.on_error.default.red }},{{ colors.on_error.default.green }},{{ colors.on_error.default.blue }}
    ForegroundNeutral={{ colors.on_primary.default.red }},{{ colors.on_primary.default.green }},{{ colors.on_primary.default.blue }}
    ForegroundNormal={{ colors.on_primary.default.red }},{{ colors.on_primary.default.green }},{{ colors.on_primary.default.blue }}
    ForegroundPositive={{ colors.on_primary.default.red }},{{ colors.on_primary.default.green }},{{ colors.on_primary.default.blue }}
    ForegroundVisited={{ colors.on_primary.default.red }},{{ colors.on_primary.default.green }},{{ colors.on_primary.default.blue }}

    [Colors:Tooltip]
    BackgroundAlternate={{ colors.surface_variant.default.red }},{{ colors.surface_variant.default.green }},{{ colors.surface_variant.default.blue }}
    BackgroundNormal={{ colors.surface_variant.default.red }},{{ colors.surface_variant.default.green }},{{ colors.surface_variant.default.blue }}
    DecorationFocus={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    DecorationHover={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    ForegroundActive={{ colors.on_surface_variant.default.red }},{{ colors.on_surface_variant.default.green }},{{ colors.on_surface_variant.default.blue }}
    ForegroundInactive={{ colors.outline.default.red }},{{ colors.outline.default.green }},{{ colors.outline.default.blue }}
    ForegroundLink={{ colors.tertiary.default.red }},{{ colors.tertiary.default.green }},{{ colors.tertiary.default.blue }}
    ForegroundNegative={{ colors.error.default.red }},{{ colors.error.default.green }},{{ colors.error.default.blue }}
    ForegroundNeutral={{ colors.secondary.default.red }},{{ colors.secondary.default.green }},{{ colors.secondary.default.blue }}
    ForegroundNormal={{ colors.on_surface_variant.default.red }},{{ colors.on_surface_variant.default.green }},{{ colors.on_surface_variant.default.blue }}
    ForegroundPositive={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    ForegroundVisited={{ colors.tertiary_container.default.red }},{{ colors.tertiary_container.default.green }},{{ colors.tertiary_container.default.blue }}

    [Colors:View]
    BackgroundAlternate={{ colors.surface_variant.default.red }},{{ colors.surface_variant.default.green }},{{ colors.surface_variant.default.blue }}
    BackgroundNormal={{ colors.surface.default.red }},{{ colors.surface.default.green }},{{ colors.surface.default.blue }}
    DecorationFocus={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    DecorationHover={{ colors.primary_container.default.red }},{{ colors.primary_container.default.green }},{{ colors.primary_container.default.blue }}
    ForegroundActive={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    ForegroundInactive={{ colors.outline.default.red }},{{ colors.outline.default.green }},{{ colors.outline.default.blue }}
    ForegroundLink={{ colors.tertiary.default.red }},{{ colors.tertiary.default.green }},{{ colors.tertiary.default.blue }}
    ForegroundNegative={{ colors.error.default.red }},{{ colors.error.default.green }},{{ colors.error.default.blue }}
    ForegroundNeutral={{ colors.secondary.default.red }},{{ colors.secondary.default.green }},{{ colors.secondary.default.blue }}
    ForegroundNormal={{ colors.on_surface.default.red }},{{ colors.on_surface.default.green }},{{ colors.on_surface.default.blue }}
    ForegroundPositive={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    ForegroundVisited={{ colors.tertiary_container.default.red }},{{ colors.tertiary_container.default.green }},{{ colors.tertiary_container.default.blue }}

    [Colors:Window]
    BackgroundAlternate={{ colors.background.default.red }},{{ colors.background.default.green }},{{ colors.background.default.blue }}
    BackgroundNormal={{ colors.background.default.red }},{{ colors.background.default.green }},{{ colors.background.default.blue }}
    DecorationFocus={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    DecorationHover={{ colors.primary_container.default.red }},{{ colors.primary_container.default.green }},{{ colors.primary_container.default.blue }}
    ForegroundActive={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    ForegroundInactive={{ colors.outline.default.red }},{{ colors.outline.default.green }},{{ colors.outline.default.blue }}
    ForegroundLink={{ colors.tertiary.default.red }},{{ colors.tertiary.default.green }},{{ colors.tertiary.default.blue }}
    ForegroundNegative={{ colors.error.default.red }},{{ colors.error.default.green }},{{ colors.error.default.blue }}
    ForegroundNeutral={{ colors.secondary.default.red }},{{ colors.secondary.default.green }},{{ colors.secondary.default.blue }}
    ForegroundNormal={{ colors.on_background.default.red }},{{ colors.on_background.default.green }},{{ colors.on_background.default.blue }}
    ForegroundPositive={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    ForegroundVisited={{ colors.tertiary_container.default.red }},{{ colors.tertiary_container.default.green }},{{ colors.tertiary_container.default.blue }}

    [General]
    ColorScheme=Matugen
    Name=Matugen
    shadeSortColumn=true

    [KDE]
    contrast=4

    [WM]
    activeBackground={{ colors.background.default.red }},{{ colors.background.default.green }},{{ colors.background.default.blue }}
    activeBlend={{ colors.primary.default.red }},{{ colors.primary.default.green }},{{ colors.primary.default.blue }}
    activeForeground={{ colors.on_background.default.red }},{{ colors.on_background.default.green }},{{ colors.on_background.default.blue }}
    inactiveBackground={{ colors.surface.default.red }},{{ colors.surface.default.green }},{{ colors.surface.default.blue }}
    inactiveBlend={{ colors.outline.default.red }},{{ colors.outline.default.green }},{{ colors.outline.default.blue }}
    inactiveForeground={{ colors.on_surface_variant.default.red }},{{ colors.on_surface_variant.default.green }},{{ colors.on_surface_variant.default.blue }}
  '';

  # ═══════════════════════════════════════════════════════════════════════
  # Matugen Configuration (template → output path mappings)
  # ═══════════════════════════════════════════════════════════════════════

  xdg.configFile."matugen/config.toml".text = ''
    [config]
    source_color_index = 0

    [templates.theme-material-blue]
    input_path = "~/.config/matugen/templates/theme-material-blue.css"
    output_path = "~/.mozilla/firefox/1arj8uom.default/chrome/theme-material-blue.css"

    [templates.waybar-colors]
    input_path = "~/.config/matugen/templates/waybar-colors.css"
    output_path = "~/.config/waybar/colors.css"
    post_hook = "pkill -SIGUSR2 waybar"

    [templates.hyprland-colors]
    input_path = "~/.config/matugen/templates/hyprland-colors.conf"
    output_path = "~/.config/hypr/matugen.conf"
    post_hook = "hyprctl reload"

    [templates.vscode-theme]
    input_path = "~/.config/matugen/templates/vscode-theme.json"
    output_path = "~/.vscode/extensions/matugen-theme/themes/matugen-theme.json"

    [templates.kitty-colors]
    input_path = "~/.config/matugen/templates/kitty-colors.conf"
    output_path = "~/.config/kitty/colors.conf"
    post_hook = "pkill -USR1 kitty"

    [templates.rofi-colors]
    input_path = "~/.config/matugen/templates/rofi-colors.rasi"
    output_path = "~/.config/rofi/colors.rasi"

    [templates.swaync-colors]
    input_path = "~/.config/matugen/templates/swaync-colors.css"
    output_path = "~/.config/swaync/colors.css"
    post_hook = "swaync-client -R; swaync-client -rs"

    [templates.vscode-raw]
    input_path = "~/.config/matugen/templates/vscode-colors"
    output_path = "~/.cache/matugen/vscode-colors"

    [templates.vscode-json]
    input_path = "~/.config/matugen/templates/vscode-colors.json"
    output_path = "~/.cache/matugen/vscode-colors.json"

    [templates.gtk3]
    input_path = "~/.config/matugen/templates/gtk3.css"
    output_path = "~/.config/gtk-3.0/gtk.css"

    [templates.gtk4]
    input_path = "~/.config/matugen/templates/gtk4.css"
    output_path = "~/.config/gtk-4.0/gtk.css"

    [templates.starship]
    input_path = "~/.config/matugen/templates/starship.toml"
    output_path = "~/.config/starship.toml"

    [templates.btop]
    input_path = "~/.config/matugen/templates/btop.theme"
    output_path = "~/.config/btop/themes/matugen.theme"

    [templates.freecad]
    input_path = "~/.config/matugen/templates/freecad.qss"
    output_path = "~/.local/share/FreeCAD/v1-1/Gui/Stylesheets/matugen.qss"

    [templates.kicad]
    input_path = "~/.config/matugen/templates/kicad.json"
    output_path = "~/.config/kicad/10.0/colors/matugen.json"

    [templates.steam]
    input_path = "~/.config/matugen/templates/steam.css"
    output_path = "~/.local/share/Steam/steamui/skins/Material-Theme/css/main/colors/matugen.css"

    [templates.kde-colors]
    input_path = "~/.config/matugen/templates/kde-colors.colors"
    output_path = "~/.local/share/color-schemes/Matugen.colors"
    post_hook = "plasma-apply-colorscheme Matugen 2>/dev/null || true"

    [templates.anki]
    input_path = "~/.config/matugen/templates/anki.css"
    output_path = "~/.local/share/Anki2/user_files/anki-matugen.css"
  '';

  # Matugen template for Anki Flashcard Cards
  xdg.configFile."matugen/templates/anki.css".text = ''
    /* Matugen Dynamic Anki Card Colors */
    .card {
      background-color: {{ colors.surface.default.hex }};
      color: {{ colors.on_surface.default.hex }};
      font-family: "Outfit", "JetBrainsMono Nerd Font", sans-serif;
    }
    .card-front {
      color: {{ colors.primary.default.hex }};
    }
    hr#answer {
      background: {{ colors.outline_variant.default.hex }};
    }
  '';

  # ═══════════════════════════════════════════════════════════════════════
  # KDE/Qt Color Scheme Integration (kdeglobals for Dolphin + all Qt apps)
  # ═══════════════════════════════════════════════════════════════════════

  # Set kdeglobals to use Matugen color scheme for Dolphin and all KDE/Qt apps
  home.file.".config/kdeglobals".text = ''
    [General]
    ColorScheme=Matugen
    Name=Matugen

    [KDE]
    contrast=4
    widgetStyle=Breeze
  '';
}
