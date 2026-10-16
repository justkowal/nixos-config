{lib, ...}: {
  # shared by the energy cost exporter and the off-peak scheduler
  options.lab.tariff = {
    name = lib.mkOption {
      type = lib.types.str;
      default = "G12";
    };
    # [start end) local time, HH:MM; windows may wrap midnight
    offPeakWindows = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          start = lib.mkOption {type = lib.types.str;};
          end = lib.mkOption {type = lib.types.str;};
        };
      });
      default = [
        {
          start = "22:00";
          end = "06:00";
        }
        {
          start = "13:00";
          end = "15:00";
        }
      ];
    };
    # gross PLN per kWh, energy + variable distribution; placeholders, copy the real numbers from the bill
    pricePeak = lib.mkOption {
      type = lib.types.float;
      default = 1.10;
    };
    priceOffPeak = lib.mkOption {
      type = lib.types.float;
      default = 0.70;
    };
  };
}
