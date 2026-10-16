#!/usr/bin/env bash
# Random wallpaper picker + matugen theme regeneration
WALLPAPER="/home/justkowal/Pictures/wallpaper.png"
WALLPAPER_DIR="/home/justkowal/Pictures/Wallpapers"

if [ -d "$WALLPAPER_DIR" ]; then
  RANDOM_WALL=$(find "$WALLPAPER_DIR" -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.webp" \) 2>/dev/null | shuf -n 1)
  if [ -n "$RANDOM_WALL" ]; then
    WALLPAPER="$RANDOM_WALL"
  fi
fi

if command -v awww &>/dev/null; then
  awww img "$WALLPAPER" --transition-type wipe --transition-step 90
fi

if command -v matugen &>/dev/null; then
  matugen image --source-color-index 0 "$WALLPAPER"
fi

notify-send -i image-x-generic "Wallpaper Changed" "Applied: $(basename "$WALLPAPER")"
