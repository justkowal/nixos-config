{lib, ...}: {
  # lets feature modules add hooks to the receiver in configuration.nix without editing it
  options.lab.webhookHooks = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    default = [];
    description = "Extra hook definitions (webhook hooks.json format) for the scale-to-zero receiver on :9100.";
  };
}
