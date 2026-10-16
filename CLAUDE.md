# CLAUDE.md

Multi-host NixOS flake (desktop, laptop, rpi4 hub, vm, iso) with a Home Manager userland. The desk layer is called **Kowal Lab** ("Lab" in short).

## Read first

- **UI, UX or desk changes:** [docs/LAB_GUIDELINES.md](docs/LAB_GUIDELINES.md). It is the source of truth for surfaces, tokens, the state bus and the add-a-feature checklist.
- **Architecture and hosts:** [docs/SYSTEM_ARCHITECTURE.md](docs/SYSTEM_ARCHITECTURE.md).
- **Keybinds and desktop:** [docs/DESKTOP_ENVIRONMENT.md](docs/DESKTOP_ENVIRONMENT.md).

## Hard rules

1. **Tokens only.** No raw px radii, hex colours or font names in UI files. Read them from the token module once it exists. Colour comes from Matugen.
2. **The island presents state.** CLIs publish events to the bus. They do not call `notify-send` for state or start their own OSD.
3. **Every feature gets a palette entry, a keymap entry and a scene hook** before it is done.
4. **Namespace.** Features are `home/<feature>.nix` with `options.lab.<feature>`. Behaviour is declared in Nix; scripts are embedded with `builtins.readFile`.
5. **Providers never block the GTK main loop.** Subprocess and network work runs on worker threads.
6. **Every layer-shell or GTK window declares an `app_id`** in the `lab.justkowal.<Name>` pattern.
7. **Nix flakes ignore untracked files.** Run `git add` on new files before `nix flake check`.
8. **Waybar and SwayNC stay as fallbacks** until the owner verifies their replacements. Never remove them.
9. **Secrets** go through sops-nix. Never commit tokens or `.env` files.

## Commands

```bash
git add -A home/ hosts/ modules/ docs/
nix flake check
nh os build .
python -m py_compile home/scripts/guis/*.py
shellcheck home/scripts/*.sh
```

## Working style

- Keep diffs tight. Show changes as minimal snippets, not whole files.
- Do not run recursive grep over the whole repo. Target files by path or use `git grep` on a specific directory.
- Commits use Conventional Commits: `<type>(<scope>): <subject>`, lowercase, no trailing period.
