# herdr-git-sync

**A [herdr](https://herdr.dev) plugin that fetches every git repo open in your workspaces, shows what's new, and lets you pick which ones to fast-forward.**

You run several workspaces, each sitting in a repo, often with an agent working in it. Before you start, you want to know which repos have upstream changes, and to pull only the ones that are safe to touch. herdr-git-sync does both from one popup.

## What it does

- **Finds your repos from your panes.** Every pane's working directory is resolved to its git checkout. Panes outside a repo are ignored. Worktrees of the same repo share one fetch.
- **Fetches in parallel, never prompts.** Fetches run with `GIT_TERMINAL_PROMPT=0` and `ssh -o BatchMode=yes`, so a locked ssh key fails fast and shows the error instead of hanging.
- **Shows status per checkout:** branch, ahead/behind its upstream, and why a checkout can't be pulled.
- **Pull is selective and fast-forward only.** After fetching, an fzf picker lists the checkouts that can fast-forward, with the incoming commits in a preview. Only the ones you pick are updated.
- **Leaves busy checkouts alone.** A checkout is never offered for pull while it has uncommitted changes, has diverged from its upstream, or has an agent in it that is working or waiting on you.
- **Fetches on startup.** Each time the herdr server starts, a plain fetch runs once in the background, so ahead/behind counts are current when you sit down. Startup never changes your branches.

```
▶ Status
⚠ ~/Code/shop [shop]: main ↑0 ↓3
⚠ ~/Code/api [api]: feat/auth ↑2 ↓1 — diverged
⚠ ~/Code/web [web]: main ↑0 ↓4 — agent working
⚠ ~/Code/site [site]: feat/form ↑0 ↓0 · base version-2 ↓2, feat/form is 5 behind it
✔ ~/.dotfiles [dotfiles]: main ↑0 ↓0
```

## Requirements

herdr 0.9.0 or newer, `bash`, `git`, `jq`, and `fzf` (for pull). Linux or macOS.

## Install

```bash
herdr plugin install iraklisg/herdr-git-sync
```

Update later with `herdr plugin update`.

## Actions

| Action | What it does |
|---|---|
| `iraklisg.git-sync.fetch` | Fetch all workspace repos and show status |
| `iraklisg.git-sync.pull` | Fetch, then pick which checkouts to fast-forward |
| `iraklisg.git-sync.fetch-here` | Same as fetch, focused workspace only |
| `iraklisg.git-sync.pull-here` | Same as pull, focused workspace only |

Bind them in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+alt+d"
type = "plugin_action"
command = "iraklisg.git-sync.fetch"
description = "git fetch all workspace repos"

[[keys.command]]
key = "prefix+alt+p"
type = "plugin_action"
command = "iraklisg.git-sync.pull"
description = "git pull (pick, ff-only) all workspace repos"

[[keys.command]]
key = "prefix+alt+shift+d"
type = "plugin_action"
command = "iraklisg.git-sync.fetch-here"
description = "git fetch current workspace repos"

[[keys.command]]
key = "prefix+alt+shift+p"
type = "plugin_action"
command = "iraklisg.git-sync.pull-here"
description = "git pull (pick, ff-only) current workspace repos"
```

In the picker: `SPACE` (or `TAB`) selects, `ctrl-a` selects all, `ENTER` applies, `ESC` cancels without changing anything.

## Base branch (opt-in)

When you work on feature branches, you usually also want your local base branch (`main`, `primary`, `version-2`, …) up to date for the next rebase. git can't reliably tell which branch that is, so it's opt-in per repo:

```bash
git -C ~/Code/site config herdr-git-sync.base version-2
```

With that set, status shows how far the local base is behind its upstream and how far your current branch is behind it. Pull offers to fast-forward the base too, without checking it out. It refuses anything but a fast-forward, and refuses a base that is checked out in another worktree (that worktree gets its own entry instead). The setting lives in the repo's `.git/config`, so nothing is added to its tracked files.

## Startup log

The startup fetch has no window. Read its output with:

```bash
herdr plugin log list --plugin iraklisg.git-sync
```
