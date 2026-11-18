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
- **Staging:** `./build.sh --stage` runs the tests and builds `build/Exalt Client Mac Staging <issue>.app`,
  named after the branch's issue number (`feature/49-...` gives "Staging 49"; no number: the
  worktree's folder name). Each has its own bundle id, data folder
  (`~/Library/Application Support/Exalt Client Mac Staging <issue>`) and settings, a blue icon and a
  "STAGING <issue>" badge, so several can be open at once. Its first run copies the installed app's
  settings. All of them and the installed app share one `drop_rates.db`, in the installed app's data
  folder. The app you start the game from decides which guard runs, and only one game runs at a time.
- **Before a PR leaves draft:** `./build.sh --stage` passes. The game, DECA's launcher and the
  staged app must be closed for the tests. `./build.sh --stage --app-only` rebuilds without them.
- **Worktrees:** give each its own `module-cache` (the default in `./build.sh`). Sharing the main
  checkout's cache breaks the bridging-header build.
- **Profiles:** marking a compatibility profile audited is my decision; propose it, don't do it.
