{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../../modules/overlays.nix
    ../../modules/boot.nix
    ../../modules/locale.nix
    ../../modules/user.nix
    ../../modules/nix-settings.nix
    ../../modules/services.nix
    ../../modules/security.nix
    ../../modules/kernel-laptop.nix
    ../../modules/graphical.nix
    ../../modules/shell.nix
    ../../modules/apps.nix
    ../../modules/systemd-minimal.nix
    ../../modules/laptop.nix
    ../../modules/networking.nix
    ../../modules/power-saving.nix
  ];

  home-manager.backupFileExtension = "backup";
  home-manager.extraSpecialArgs = {
    laptop = true;
  };

  hardware.enableRedistributableFirmware = true;
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;
  services.fwupd.enable = true;

  # Laptop Battery Power Management, Thermal Control & Battery Health Preservation
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      RUNTIME_PM_ON_AC = "auto";
      RUNTIME_PM_ON_BAT = "auto";
      SATA_LINKPWR_ON_BAT = "min_power";
      WIFI_PWR_ON_AC = "off";
      WIFI_PWR_ON_BAT = "on";
      # ThinkPad Battery Health Thresholds (Mild Conservation Mode: 85% - 90%)
      START_CHARGE_THRESH_BAT0 = 85;
      STOP_CHARGE_THRESH_BAT0 = 90;
    };
  };

  # Touchpad & TrackPoint support (Libinput & ThinkPad TrackPoint Driver)
  services.libinput = {
    enable = true;
    touchpad = {
      tapping = true;
      naturalScrolling = true;
      scrollMethod = "twofinger";
    };
  };
  hardware.trackpoint = {
    enable = true;
    emulateWheel = true;
  };

  # Backlight brightness control without root privileges
  hardware.acpilight.enable = true;
  services.upower.enable = true;

  # Deep sleep power savings (avoids Modern Standby battery drain on ThinkPad AMD)
  boot.kernelParams = [
    "mem_sleep_default=deep"
    # Initrd Hardening (prevent dropping to root debug shell on failure)
    "rd.shell=0"
    "rd.emergency=reboot"
    # Kernel & Memory Exploit Mitigations
    "page_alloc.shuffle=1"
    "slab_nomerge"
    "init_on_alloc=1"
    "init_on_free=1"
    "vsyscall=none"
    "debugfs=off"
    "oops=panic"
    "lockdown=integrity"
  ];

  # Secure Boot via Lanzaboote (signs kernels and bootloader with sbctl keys)
  security.protectKernelImage = true;
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.systemd-boot.editor = false;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
    settings = {
      editor = false;
    };
  };

  # Logind lid switch handling: suspend on battery, keep active when docked/external monitor
  services.logind.settings = {
    Login = {
      HandleLidSwitch = "suspend";
      HandleLidSwitchDocked = "ignore";
      HandleLidSwitchExternalPower = "ignore";
    };
  };

  # Biometrics: Synaptics Prometheus MIS Touch Fingerprint Reader (06cb:00bd)
  services.fprintd.enable = true;

  # Allow members of wheel group to enroll fingerprints, and allow justkowal to trigger unlock-keyring
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id.indexOf("net.reactivated.fprint.") == 0 && subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "unlock-keyring.service" &&
          subject.user == "justkowal") {
        return polkit.Result.YES;
      }
    });
  '';

  # Biometrics: Windows Hello facial recognition via ThinkPad IR Camera (/dev/video2)
  services.howdy = {
    enable = true;
    control = "sufficient"; # NEVER "required" — prevents locking out password auth
    settings = {
      core = {
        abort_if_lid_closed = true;
        abort_if_ssh = true;
      };
      video = {
        device_path = "/dev/video2";
        dark_threshold = 95;
        certainty = 3.5;
      };
    };
  };

  # IR Emitter Hardware Service for infrared illumination
  services.linux-enable-ir-emitter.enable = true;

  # PAM Authentication integration (Hyprlock: Face in PAM + parallel Fingerprint; Greetd: Face first then Fingerprint/Password)
  security.pam.services = {
    hyprlock = {
      fprintAuth = false; # Handled in parallel natively by hyprlock (avoids serial PAM blocking)
      howdy = {
        enable = true;
        control = "sufficient";
      };
    };
    greetd = {
      rules.auth.howdy.order = lib.mkForce 11300; # Run Howdy BEFORE fprintd so camera triggers first
    };
    sudo = {
      fprintAuth = true;
      howdy.enable = false;
    };
    polkit-1 = {
      fprintAuth = true;
      howdy.enable = false;
    };
    login = {
      howdy.enable = false;
    };
  };


  # TPM 2.0 Hardware Security Subsystem
  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  # Hardware TPM2 Keyring Unsealer Service (completely eliminates insecure NOPASSWD sudo rule)
  systemd.services.unlock-keyring = {
    description = "Hardware TPM2 Keyring Unsealer";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      LoadCredentialEncrypted = "keyring:/etc/keyring.cred";
      ExecStart = pkgs.writeShellScript "unlock-keyring-tpm-service" ''
        if [ -s "$CREDENTIALS_DIRECTORY/keyring" ] && [ -S "/run/user/1000/bus" ]; then
          exec ${pkgs.su}/bin/su -s /bin/sh justkowal -c "export DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus'; exec ${pkgs.writers.writePython3Bin "unlock-keyring-tool" {
            libraries = [pkgs.python3Packages.jeepney];
          } ''
            import sys
            from jeepney import DBusAddress, new_method_call
            from jeepney.io.blocking import open_dbus_connection

            password = sys.stdin.read().strip()
            if not password:
                print("Keyring unlock failed: No password provided in credential", file=sys.stderr)
                sys.exit(1)

            try:
                conn = open_dbus_connection(bus="SESSION")
                service = DBusAddress(
                    "/org/freedesktop/secrets",
                    "org.freedesktop.secrets",
                    "org.freedesktop.Secret.Service",
                )
                msg = new_method_call(
                    service, "OpenSession", "sv", ("plain", ("s", ""))
                )
                _, session_path = conn.send_and_get_reply(msg).body

                guilt = DBusAddress(
                    "/org/freedesktop/secrets",
                    "org.freedesktop.secrets",
                    "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface",
                )
                secret = (session_path, b"", password.encode(), "text/plain")
                msg_unlock = new_method_call(
                    guilt,
                    "UnlockWithMasterPassword",
                    "o(oayays)",
                    ("/org/freedesktop/secrets/collection/login", secret),
                )
                reply = conn.send_and_get_reply(msg_unlock)
                if reply.body:
                    print(f"Keyring unlock failed: {reply.body[0]}", file=sys.stderr)
                    sys.exit(1)
                print("Keyring successfully unlocked.")
            except Exception as e:
                print(f"Keyring unlock exception: {e}", file=sys.stderr)
                sys.exit(1)
          ''}/bin/unlock-keyring-tool" < "$CREDENTIALS_DIRECTORY/keyring"
        fi
      '';
    };
  };

  # Laptop-specific packages
  environment.systemPackages = with pkgs; [
    brightnessctl
    wireplumber
    libnotify
    howdy
    fprintd
    tpm2-tools
    cryptsetup
    seahorse
    sbctl
    e2fsprogs
  ];

  # Hostname
  networking.hostName = "thinkpad-t14s-gen1-amd";

  # Networking
  networking.networkmanager.enable = true;

  # Define user account
  users.users.justkowal = {
    isNormalUser = true;
    description = "justkowal";
    extraGroups = ["networkmanager" "wheel" "video" "render" "docker" "input" "tss"];
  };

  # NixOS State Version
  system.stateVersion = "26.05";
}
