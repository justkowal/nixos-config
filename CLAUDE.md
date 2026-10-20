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
5. **Providers never block the GTK main loop.** Subprocess and network work runs on worker threads. The bus and the island are Rust (`pkgs/labd`); providers and CLIs are Python or shell.
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

## Tool use

MCP tools are deferred: load schemas with one ToolSearch call before first use, batching every tool you expect to need. Prefer a dedicated tool over shell text munging.

- **Find code with the graph first.** Before `grep`, `find`, `ls -R`, `sed` or `awk` to explore, load and call `code-review-graph`: `select:mcp__code-review-graph__semantic_search_nodes_tool,mcp__code-review-graph__query_graph_tool,mcp__code-review-graph__get_minimal_context_tool,mcp__code-review-graph__get_impact_radius_tool`. Use `get_impact_radius_tool` before changing a shared symbol and `detect_changes_tool` before declaring a diff done. If the graph looks stale, run `build_or_update_graph_tool` once, then retry.
- **Graph gaps.** The graph covers Rust (`pkgs/labd`), Python and shell well, `.nix` poorly. For `.nix` use `git grep -n <pattern> -- home/ hosts/ modules/` on a named directory. Never recurse over the whole repo.
- **Read narrowly.** Use `Read` with `offset` and `limit` on the lines you need. Do not `cat` or `sed -n` a file you could `Read`, and do not re-read a file you just edited.
- **Nix facts come from the nixos MCP.** Package names, option paths, channels and versions: `mcp__nixos__nix` and `nix_versions`, not `nix search` or guessing. Library and API docs: `context7`.
- **Lab runtime state comes from the kowallab MCP** (`lab_status`, `lab_doctor`, `lab_events`), not by tailing logs or poking the socket.
- **Parallelise.** Independent reads and searches go in one message. Run slow builds (`nh os build .`, `nix flake check`) in the background and keep working.
- **Subagents get the same rules.** A spawned agent only knows its prompt. Put the graph tool names and the ToolSearch line in it, name the files or directory to look at, and say what the answer should look like. Do not spawn one for a lookup that takes two tool calls.
- **Verify cheaply.** After an edit run the narrowest check that covers it (`python -m py_compile <file>`, `shellcheck <file>`, `nix eval` on the option) and run the full `nix flake check` once at the end.
