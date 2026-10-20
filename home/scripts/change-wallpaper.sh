#!/usr/bin/env bash
# Wallpaper picker: each wallpaper in the folder is a theme.
# Files with a fixed source colour are listed in THEME_COLORS below, the rest use auto extraction.
WALLPAPER_DIR="/home/justkowal/Pictures/Wallpapers"
declare -A THEME_COLORS=(
  ["tapeta-od-milosci.png"]="#6385b0"
)

PICK=$(find "$WALLPAPER_DIR" -maxdepth 1 -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.webp" \) -printf "%f\n" 2>/dev/null | sort | rofi -dmenu -i -p "Wallpaper")
[ -z "$PICK" ] && exit 0

WALLPAPER="$WALLPAPER_DIR/$PICK"

if command -v awww &>/dev/null; then
  awww img "$WALLPAPER" --transition-type wipe --transition-step 90
fi

# the active theme pack picks the scheme and the mode, plain matugen is the fallback
if command -v lab &>/dev/null && lab theme --colors "$WALLPAPER"; then
  :
elif command -v matugen &>/dev/null; then
  matugen image --source-color-index 0 "$WALLPAPER"
fi

# a fixed source colour replaces what was extracted from the image
if [ -n "${THEME_COLORS[$PICK]}" ] && command -v matugen &>/dev/null; then
  matugen color hex "${THEME_COLORS[$PICK]}"
fi

# labd and the widgets read colours once at start, so both need a restart to follow the new theme
systemctl --user restart labd.service 2>/dev/null
systemctl --user restart deskwidgets.service 2>/dev/null

notify-send -i image-x-generic "Wallpaper Changed" "Applied: $PICK"
