# Exalt Client Mac

The workflow (GitHub Issues, one session per issue) is in my user-level CLAUDE.md. Specifics for
this repo:

- **Backlog:** [ehongkuo/exalt-client-mac issues](https://github.com/ehongkuo/exalt-client-mac/issues).
  The repo is **public**: no account names, tokens or personal details in issues or PRs.
- **Nexus on death work** cites its phase and issue letter in the
  [hardening plan](docs/nexus-hardening-plan.md) (for example "Phase 3 G") and keeps that plan in step
  with the issue.
- **Before a PR leaves draft:** `./build.sh` passes. The game, DECA's launcher and the app must be
  closed. While the game runs, `./build.sh --app-only` installs without the tests.
- **Worktrees:** give each its own `module-cache` (the default in `./build.sh`). Sharing the main
  checkout's cache breaks the bridging-header build.
- **Profiles:** marking a compatibility profile audited is my decision; propose it, don't do it.
