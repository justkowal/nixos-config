---
name: python-gui
description: Guide for lightweight Python desktop GUI applications (PyQt6 / PySide6 / Tkinter). Focuses on responsive UI, non-blocking asynchronous event loops, clean styling, and proper thread isolation.
---

# Python GUI Development Guide

Wzorzec projektowania nowoczesnych, lekkich i responsywnych aplikacji okienkowych w Pythonie (np. PyQt6, PySide6, CustomTkinter) w środowisku Linux/Wayland (Hyprland).

## 1. Architektura UI i Wątkowość
- **Nigdy nie blokuj głównego wątku (Main GUI Thread):**
  - Długotrwałe operacje (I/O, skanowanie sprzętu, komendy powłoki, odpytywanie sieciowe) wykonuj w dedykowanych wątkach robotniczych (`QThread`, `ThreadPoolExecutor`, `asyncio`).
  - Komunikację między wątkami a interfejsem realizuj wyłącznie za pomocą mechanizmu sygnałów i slotów (`pyqtSignal` / `Signal`), nigdy przez bezpośrednie modyfikowanie widżetów z innego wątku.
- **Bezpieczne zamykanie procesów:**
  - Obsługuj sygnał `SIGINT` i zdarzenie zamykania okna (`closeEvent`), aby prawidłowo zakończyć procesy potomne bez zawieszania pulpitu.

## 2. Estetyka i Dopasowanie do Pulpitu (Wayland / Hyprland)
- **Kompatybilność z Wayland:** Upewnij się, że okna poprawnie zgłaszają `app_id` (współpraca z regułami okien w Hyprland).
- **Styling:**
  - Używaj spójnych palet barw (ciemny motyw zgodny z systemem, unikanie jaskrawych, domyślnych kolorów).
  - Stosuj arkusze stylów QSS lub nowoczesne biblioteki stylujące z czytelną typografią i ergonomicznym paddingiem.
