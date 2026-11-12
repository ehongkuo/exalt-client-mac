# Exalt Client Mac

The workflow (GitHub Issues, one session per issue) is in my user-level CLAUDE.md. Specifics for
this repo:

- **Backlog:** [ehongkuo/exalt-client-mac issues](https://github.com/ehongkuo/exalt-client-mac/issues).
  The repo is **public**: no account names, tokens or personal details in issues or PRs.
- **Nexus on death work** cites its phase and issue letter in the
  [hardening plan](docs/nexus-hardening-plan.md) (for example "Phase 3 G") and keeps that plan in step
  with the issue.
- **Order of work:** issue → worktree + session → `./build.sh --stage` and live-test → merge →
  `./build.sh` on main installs to ~/Applications. ~/Applications holds the app I play with: never
  install to it from a PR branch.
- **Staging:** `./build.sh --stage` runs the tests and builds `build/Exalt Client Mac Staging.app`
  (own bundle id, own data folder `~/Library/Application Support/Exalt Client Mac Staging`, blue
  icon, "STAGING" badge). Its first run copies the installed app's settings. The app you start the
  game from decides which guard runs, and only one game runs at a time: quit one app before
  opening the other.
- **Before a PR leaves draft:** `./build.sh --stage` passes. The game, DECA's launcher and the
  staged app must be closed for the tests. `./build.sh --stage --app-only` rebuilds without them.
- **Worktrees:** give each its own `module-cache` (the default in `./build.sh`). Sharing the main
  checkout's cache breaks the bridging-header build.
- **Profiles:** marking a compatibility profile audited is my decision; propose it, don't do it.
