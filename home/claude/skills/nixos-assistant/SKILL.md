---
name: nixos-assistant
description: Expert assistant for NixOS, Flakes, Home-Manager, and system derivations. Helps with declarative system maintenance, debugging build failures, optimizing nix store, and flake management.
---

# NixOS & Flake Assistant

Specjalistyczny asystent do pracy z NixOS, Nix Flakes, Home-Manager oraz językiem Nix.

## 1. Dobre Praktyki w Repozytorium NixOS
- **Struktura modułowa:** Utrzymuj separację między konfiguracją systemową (`/etc/nixos/modules/`), specyfikacją maszyny (`/etc/nixos/hosts/<host>/`) a konfiguracją użytkownika (Home-Manager).
- **Flaki (`flake.nix` & `flake.lock`):**
  - Wszystkie zależności zewnętrzne deklaruj jako `inputs`.
  - Pamiętaj, że nowe pliki w repozytorium muszą być dodane do git (`git add`) przed wykonaniem `nixos-rebuild`, inaczej Nix Flakes ich nie widzi.
- **Bezpieczeństwo i Sekrety:**
  - Sekrety przechowuj zaszyfrowane przez `sops-nix` lub `agenix`. Nigdy nie commituj haseł i kluczy w postaci otwartej.

## 2. Diagnozowanie Problemów i Optymalizacja
- **Śledzenie błędów ewaluacji:** Używaj `--show-trace` przy awarii ewaluacji.
- **Zapytania o pakiety i atrybuty:** Preferuj `nix eval` oraz `nix-tree` / `nix-locate` zamiast pełnego przeszukiwania całego kanału.
- **Zarządzanie przestrzenią dyskową:**
  - Usuwanie starych generacji: `sudo nix-collect-garbage -d` oraz `nh clean all`.
  - Optymalizacja hardlinków w store: `nix-store --optimise`.
