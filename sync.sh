#!/usr/bin/env bash
# sync.sh — fetch every git repo open in herdr panes, then fast-forward the ones you pick
#
# Usage: sync.sh fetch|pull [all|here]
#        sync.sh startup
#        sync.sh preview <checkout>    (fzf preview, used internally)
#
# Repos are discovered from pane cwds: across all workspaces, or only the
# focused one with "here". Fetches run in parallel, once per repository
# (worktrees share one fetch), and never prompt for credentials.
#
# pull fetches, shows status, then lets you pick which checkouts to
# fast-forward. Checkouts that are dirty, diverged or have an agent working
# in them are listed but cannot be picked. A repo can opt into also
# fast-forwarding its local base branch with:
#   git config herdr-git-sync.base <branch>

set -o nounset
set -o pipefail

mode=${1:-fetch}
herdr=${HERDR_BIN_PATH:-herdr}
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
base_key=herdr-git-sync.base

# Never wait on a password or passphrase nobody will type: fail fast instead.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=10}

_bold="" _dim="" _red="" _green="" _yellow="" _blue="" _nc=""
if [[ -t 1 && -z ${NO_COLOR-} ]] || [[ $mode == preview ]]; then
    _bold=$'\033[1m' _dim=$'\033[2m' _red=$'\033[0;31m' _green=$'\033[0;32m'
    _yellow=$'\033[0;33m' _blue=$'\033[0;34m' _nc=$'\033[0m'
fi

msg()  { printf '\n%s\n' "${_bold}▶ ${1}${_nc}"; }
ok()   { printf '%s\n' "${_green}✔${_nc} ${1}"; }
warn() { printf '%s\n' "${_yellow}⚠${_nc} ${1}"; }
err()  { printf '%s\n' "${_red}✘${_nc} ${1}"; }
short() { printf '%s' "${1/#$HOME/\~}"; }
indent() { sed 's/^/    /'; }

finish() {
    if [[ -t 0 && -t 1 ]]; then
        printf '\n%s' "${_dim}Press any key to close${_nc}"
        read -rsn1
    fi
    exit "${1:-0}"
}

# Incoming commits for one checkout: its branch, then its opted-in base branch.
preview() {
    local top=$1 branch base
    branch=$(git -C "$top" symbolic-ref --short -q HEAD)
    [[ -n $branch ]] && incoming "$top" "$branch"
    base=$(git -C "$top" config --get "$base_key")
    [[ -n $base && $base != "$branch" ]] && incoming "$top" "$base"
}

# incoming <checkout> <branch>: commits on the branch's upstream not yet in it
incoming() {
    local log
    log=$(git -C "$1" --no-pager log --oneline --color=always "$2..$2@{u}" 2>/dev/null)
    [[ -n $log ]] || return 0
    printf '%s\n%s\n\n' "${_bold}$2 ← $(git -C "$1" rev-parse --abbrev-ref "$2@{u}")${_nc}" "$log"
}

case $mode in
    preview) preview "$2"; exit ;;
    startup) scope=all ;;
    fetch|pull) scope=${2:-all} ;;
    *) err "unknown mode: $mode"; finish 1 ;;
esac

scope_ws=""
if [[ $scope == here ]]; then
    scope_ws=$(jq -r '.workspace_id // empty' <<<"${HERDR_PLUGIN_CONTEXT_JSON:-{\}}")
    scope_ws=${scope_ws:-${HERDR_WORKSPACE_ID-}}
    [[ -n $scope_ws ]] || { err "No focused workspace"; finish 1; }
fi

# workspace_id -> label
declare -A labels
while IFS=$'\t' read -r id label; do
    labels[$id]=$label
done < <("$herdr" workspace list | jq -r '.result.workspaces[] | [.workspace_id, .label] | @tsv')

# checkouts: toplevel -> workspace label(s)
# repos:     git common dir -> one toplevel to fetch from
# busy:      toplevel -> set when an agent there is working or waiting on you
declare -A checkouts repos busy
while IFS=$'\t' read -r ws cwd status; do
    [[ -z $scope_ws || $ws == "$scope_ws" ]] || continue
    top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || continue
    common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)
    label=${labels[$ws]:-$ws}
    [[ ${checkouts[$top]-} == *"$label"* ]] || checkouts[$top]+="${checkouts[$top]:+, }$label"
    repos[$common]=${repos[$common]:-$top}
    [[ $status == working || $status == blocked ]] && busy[$top]=1
done < <("$herdr" pane list | jq -r '.result.panes[] | [.workspace_id, .cwd, .agent_status] | @tsv')

if (( ${#checkouts[@]} == 0 )); then
    warn "No git repos found in workspace panes"
    finish
fi

msg "Fetching ${#repos[@]} repo(s)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
declare -A logs
declare -a pids
i=0
for common in "${!repos[@]}"; do
    top=${repos[$common]}
    logs[$top]=$tmp/$((i++))
    git -C "$top" fetch --all --prune --quiet >"${logs[$top]}" 2>&1 &
    pids[$!]=$top
done

failed=0
for pid in "${!pids[@]}"; do
    top=${pids[$pid]}
    if wait "$pid"; then
        ok "$(short "$top")"
    else
        err "$(short "$top")"
        indent <"${logs[$top]}"
        failed=1
    fi
done

[[ $mode == startup ]] && exit "$failed"

# Status, and what pull could apply per checkout.
# apply_branch: toplevel -> set when its branch can fast-forward
# apply_base:   toplevel -> opted-in base branch that can fast-forward
declare -A apply_branch apply_base
candidates=()
msg "Status"
while IFS= read -r top; do
    name="$(short "$top") ${_blue}[${checkouts[$top]}]${_nc}"
    branch=$(git -C "$top" symbolic-ref --short -q HEAD) || { warn "$name: detached HEAD"; continue; }

    state=$branch behind=0 blockers=()
    if git -C "$top" rev-parse -q --verify '@{u}' >/dev/null; then
        read -r ahead behind < <(git -C "$top" rev-list --left-right --count 'HEAD...@{u}')
        state+=" ↑$ahead ↓$behind"
        if (( behind > 0 )); then
            [[ -n $(git -C "$top" status --porcelain --untracked-files=no | head -1) ]] && blockers+=("uncommitted changes")
            (( ahead > 0 )) && blockers+=("diverged")
            [[ -n ${busy[$top]-} ]] && blockers+=("agent working")
            (( ${#blockers[@]} == 0 )) && apply_branch[$top]=1
        fi
    else
        state+=" (no upstream)"
    fi

    base=$(git -C "$top" config --get "$base_key")
    base_behind=0
    if [[ -n $base && $base != "$branch" ]]; then
        if ! git -C "$top" rev-parse -q --verify "refs/heads/$base" >/dev/null; then
            state+=" · base $base missing"
        elif ! git -C "$top" rev-parse -q --verify "$base@{u}" >/dev/null; then
            state+=" · base $base has no upstream"
        else
            read -r base_ahead base_behind < <(git -C "$top" rev-list --left-right --count "$base...$base@{u}")
            lag=$(git -C "$top" rev-list --count "HEAD..$base@{u}")
            state+=" · base $base ↓$base_behind, $branch is $lag behind it"
            if (( base_ahead > 0 )); then
                state+=" (base diverged)"
            elif (( base_behind > 0 )); then
                apply_base[$top]=$base
            fi
        fi
    fi

    if (( ${#blockers[@]} > 0 )); then
        printf -v joined '%s, ' "${blockers[@]}"
        state+=" — ${joined%, }"
    fi
    if (( behind > 0 || base_behind > 0 )); then warn "$name: $state"; else ok "$name: $state"; fi

    if [[ -n ${apply_branch[$top]-} || -n ${apply_base[$top]-} ]]; then
        what=()
        [[ -n ${apply_branch[$top]-} ]] && what+=("$branch ↓$behind")
        [[ -n ${apply_base[$top]-} ]] && what+=("base $base ↓$base_behind")
        printf -v joined '%s · ' "${what[@]}"
        candidates+=("$top"$'\t'"$(short "$top") [${checkouts[$top]}]  ${joined% · }")
    fi
done < <(printf '%s\n' "${!checkouts[@]}" | sort)

[[ $mode == pull ]] || finish "$failed"

if (( ${#candidates[@]} == 0 )); then
    msg "Nothing to fast-forward"
    finish "$failed"
fi

command -v fzf >/dev/null || { err "pull needs fzf to pick checkouts"; finish 1; }

picked=$(printf '%s\n' "${candidates[@]}" | fzf --multi --ansi --delimiter=$'\t' --with-nth=2 \
    --header 'SPACE select · ctrl-a all · ENTER apply · ESC cancel' \
    --bind 'space:toggle+down,ctrl-a:select-all' \
    --preview "bash $(printf '%q' "$self") preview {1}" --preview-window=down,60%) || {
    msg "Cancelled, nothing applied"
    finish "$failed"
}

msg "Fast-forwarding"
while IFS=$'\t' read -r top _; do
    name=$(short "$top")
    if [[ -n ${apply_branch[$top]-} ]]; then
        branch=$(git -C "$top" symbolic-ref --short HEAD)
        if out=$(git -C "$top" merge --ff-only --quiet '@{u}' 2>&1); then
            ok "$name: $branch"
        else
            err "$name: $branch"; indent <<<"$out"; failed=1
        fi
    fi
    if [[ -n ${apply_base[$top]-} ]]; then
        base=${apply_base[$top]}
        # Non-forced refspec: refuses anything but a fast-forward, and refuses
        # a branch checked out in another worktree.
        upstream=$(git -C "$top" rev-parse --symbolic-full-name "$base@{u}")
        if out=$(git -C "$top" fetch --quiet . "$upstream:refs/heads/$base" 2>&1); then
            ok "$name: base $base"
        else
            err "$name: base $base"; indent <<<"$out"; failed=1
        fi
    fi
done <<<"$picked"

finish "$failed"
