{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.lab.boot.splash;

  # the Lab mark (four brackets and a dot, the focus glyph) drawn once at build time
  logo = pkgs.runCommand "lab-logo.png" {nativeBuildInputs = [(pkgs.python3.withPackages (ps: [ps.pycairo]))];} ''
    python3 - <<'EOF'
    import cairo
    size = 192
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    cr = cairo.Context(surf)
    cr.scale(size / 24, size / 24)
    cr.set_source_rgb(1, 1, 1)
    cr.set_line_width(1.5)
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    cr.set_line_join(cairo.LINE_JOIN_ROUND)
    for pts in (((3, 8), (3, 3), (8, 3)), ((16, 3), (21, 3), (21, 8)),
                ((21, 16), (21, 21), (16, 21)), ((8, 21), (3, 21), (3, 16))):
        cr.move_to(*pts[0])
        for p in pts[1:]:
            cr.line_to(*p)
        cr.stroke()
    cr.arc(12, 12, 3, 0, 6.2832)
    cr.fill()
    surf.write_to_png("logo.png")
    EOF
    cp logo.png $out
  '';
in {
  options.lab.boot.splash.enable = lib.mkEnableOption ''
    the boot splash: the stock plymouth spinner theme with the Lab mark. Off by default and untested on
    hardware here. Enable it on the desktop first (no disk encryption), keep an older generation to boot
    from, and on the encrypted laptop confirm the passphrase prompt shows up before relying on it
  '';

  config = lib.mkIf cfg.enable {
    boot.plymouth = {
      enable = true;
      # the stock theme, because it implements the passphrase prompt; a hand-written script theme
      # without one would hide the LUKS prompt
      theme = "spinner";
      inherit logo;
    };
  };
}
