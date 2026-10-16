{
  config,
  lib,
  pkgs,
  ...
}: let
  ci-energy-cost = pkgs.writeShellApplication {
    name = "ci-energy-cost";
    runtimeInputs = [pkgs.curl pkgs.jq];
    text = ''
      if [ $# -ne 2 ]; then
        echo "usage: ci-energy-cost <start-unix> <end-unix>" >&2
        exit 2
      fi
      # pl_PL numeric locale makes printf reject "0.123"
      export LC_ALL=C
      start=$1
      end=$2
      vm=''${VM_URL:-http://nixos-rpi4.lab:8428}
      dur=$((end - start))
      if [ "$dur" -le 0 ]; then
        echo "end must be after start" >&2
        exit 2
      fi
      # rounded up to whole minutes so the 1m subquery steps cover short jobs
      win=$(( (dur + 59) / 60 * 60 ))

      query() {
        curl -fsS --get "$vm/api/v1/query" \
          --data-urlencode "query=$1" --data-urlencode "time=$end" \
          | jq -r '.data.result[0].value[1] // "0"'
      }

      kwh=$(query "sum(increase(shelly_aenergy_wh_total[''${win}s])) / 1000")
      pln=$(query "sum_over_time((sum(increase(shelly_aenergy_wh_total[1m])) / 1000 * max(electricity_price_pln_per_kwh))[''${win}s:1m])")

      printf 'energy: %.3f kWh\ncost: %.2f PLN\n' "$kwh" "$pln"
    '';
  };
in {
  options.lab.energyCost.enable = lib.mkEnableOption "the ci-energy-cost CLI (kWh and PLN for a time window)";

  config = lib.mkIf config.lab.energyCost.enable {
    environment.systemPackages = [ci-energy-cost];
  };
}
