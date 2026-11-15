#!/bin/bash
# User part of the guest setup, run by aidevops-vm.sh as the VM user on every run. Idempotent.
# Needs HOME, XDG_RUNTIME_DIR and a logged-in gh. Environment: PULSE, MAX_WORKERS, RAM_RESERVE_MB, REPOS,
# INSTRUCTIONS_REPO and INSTRUCTIONS_FILES (both optional).
set -euo pipefail

: "${PULSE:?}" "${MAX_WORKERS:?}" "${RAM_RESERVE_MB:?}"
REPOS="${REPOS:-}"
INSTRUCTIONS_REPO="${INSTRUCTIONS_REPO:-}"
INSTRUCTIONS_FILES="${INSTRUCTIONS_FILES:-}"

export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
CLONE="$HOME/Git/aidevops"
REPOS_JSON="$HOME/.config/aidevops/repos.json"
PULSE_TIMER=aidevops-supervisor-pulse.timer
LABEL_HELPER="$HOME/.aidevops/agents/scripts/label-sync-helper.sh"
UPSTREAM_SLUG=marcusquinn/aidevops

if [ "$PULSE" = on ]; then pulse_bool=true; else pulse_bool=false; fi

# ---- npm prefix the user can write ------------------------------------------
# lib/ must exist: aidevops falls back to `sudo npm install -g` (into /usr, on the system disk a rebuild replaces)
# when the prefix's lib/ is not writable.
mkdir -p "$HOME/.npm-global/lib" "$HOME/.npm-global/bin"
npm config set prefix "$HOME/.npm-global"
profile_line='export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"'
grep -qxF "$profile_line" "$HOME/.profile" 2>/dev/null || printf '%s\n' "$profile_line" >> "$HOME/.profile"

# ---- npm tools aidevops' linters use and its updater does not cover: installed now, updated daily ------
NPM_TOOLS="markdownlint-cli2"
for tool in $NPM_TOOLS; do
  command -v "$tool" >/dev/null || npm install -g "$tool@latest"
done
units="$HOME/.config/systemd/user"
mkdir -p "$units"
printf '%s\n' '[Unit]' 'Description=Install the latest npm tools of aidevops-vm' '' '[Service]' 'Type=oneshot' \
  "ExecStart=/usr/bin/npm install -g $(printf '%s@latest ' $NPM_TOOLS)" > "$units/aidevops-vm-npm-tools.service"
printf '%s\n' '[Unit]' 'Description=Daily npm tool update' '' '[Timer]' 'OnCalendar=daily' 'Persistent=true' '' \
  '[Install]' 'WantedBy=timers.target' > "$units/aidevops-vm-npm-tools.timer"
systemctl --user daemon-reload
systemctl --user enable --now aidevops-vm-npm-tools.timer

# ---- aidevops clone: the updater owns it after this --------------------------
if [ ! -d "$CLONE/.git" ]; then
  mkdir -p "$HOME/Git"
  git clone "https://github.com/$UPSTREAM_SLUG" "$CLONE"
fi

pulse_timer_present() {
  systemctl --user cat "$PULSE_TIMER" >/dev/null 2>&1
}

pulse_timer_enabled() {
  systemctl --user is-enabled --quiet "$PULSE_TIMER" 2>/dev/null
}

# ---- OpenCode config: setup registers aidevops' plugin in it only when the file exists ----------------
OPENCODE_JSON="$HOME/.config/opencode/opencode.json"
mkdir -p "$(dirname "$OPENCODE_JSON")"
[ -f "$OPENCODE_JSON" ] || printf '{"$schema": "https://opencode.ai/config.json"}\n' > "$OPENCODE_JSON"

# ---- setup runs on first install, when the pulse timer is missing while PULSE=on, or when the plugin is not
# ---- registered in opencode.json ----------------------------------------------------------------------
need_setup=0
[ -f "$HOME/.aidevops/agents/VERSION" ] || need_setup=1
if [ "$PULSE" = on ] && ! pulse_timer_present && [ ! -f "$HOME/.aidevops/logs/pulse-session.stop" ]; then
  need_setup=1
fi
grep -q 'opencode-aidevops' "$OPENCODE_JSON" || need_setup=1
# The ~/.local/bin/opencode shim survives a rebuild on the home volume; setup reinstalls a target that is gone.
"$HOME/.local/bin/opencode" --version >/dev/null 2>&1 || need_setup=1
if [ "$need_setup" = 1 ]; then
  # Consent for the pulse is read at setup time: the config file when it exists, the env var otherwise.
  bash "$CLONE/.agents/scripts/config-helper.sh" set orchestration.supervisor_pulse "$pulse_bool" \
    || echo "-- config-helper could not write before the first setup; relying on the env override --"
  setup_log="$(mktemp)"
  # setup.sh checks its location with pwd, so it runs from inside the clone.
  (cd "$CLONE" && AIDEVOPS_SUPERVISOR_PULSE="$pulse_bool" AIDEVOPS_MAX_WORKERS_CAP="$MAX_WORKERS" \
    bash ./setup.sh --non-interactive </dev/null 2>&1) | tee "$setup_log"
  grep -q '^\[SETUP_COMPLETE\]' "$setup_log" || { echo "ERROR: setup.sh did not reach [SETUP_COMPLETE]" >&2; exit 1; }
  rm -f "$setup_log"
fi

AIDEVOPS="$(command -v aidevops || true)"
[ -n "$AIDEVOPS" ] || AIDEVOPS="$CLONE/aidevops.sh"

# ---- Go fetches the toolchain a go.mod names ----------------------------------------------------------
if [ "$(go env GOTOOLCHAIN)" != auto ]; then go env -w GOTOOLCHAIN=auto; fi

# ---- git ignores aidevops runtime state, so git add -A in a worktree never stages it -------------------
mkdir -p "$HOME/.config/git"
for ignored in .agents/loop-state/ .agents/tmp/ .agents/memory/ .agents/.full-loop-cleanup-deferred; do
  grep -qxF "$ignored" "$HOME/.config/git/ignore" 2>/dev/null || printf '%s\n' "$ignored" >> "$HOME/.config/git/ignore"
done

# ---- config, timers ----------------------------------------------------------
"$AIDEVOPS" config set orchestration.supervisor_pulse "$pulse_bool"
"$AIDEVOPS" config set orchestration.max_workers_cap "$MAX_WORKERS"
if [ "$PULSE" = on ]; then
  if [ ! -f "$HOME/.aidevops/logs/pulse-session.stop" ] && pulse_timer_present && ! pulse_timer_enabled; then
    systemctl --user enable --now "$PULSE_TIMER"
  fi
elif pulse_timer_enabled; then
  systemctl --user disable --now "$PULSE_TIMER"
fi
"$AIDEVOPS" auto-update enable --idempotent
"$AIDEVOPS" repo-sync enable

dropin_dir="$HOME/.config/systemd/user/aidevops-supervisor-pulse.service.d"
mkdir -p "$dropin_dir"
printf '[Service]\nEnvironment=RAM_RESERVE_MB=%s\n' "$RAM_RESERVE_MB" > "$dropin_dir/10-memory.conf.new"
if ! cmp -s "$dropin_dir/10-memory.conf.new" "$dropin_dir/10-memory.conf" 2>/dev/null; then
  mv "$dropin_dir/10-memory.conf.new" "$dropin_dir/10-memory.conf"
else
  rm -f "$dropin_dir/10-memory.conf.new"
fi
systemctl --user daemon-reload

# ---- repos -------------------------------------------------------------------
# The login gh stored, read offline so a rate-limited API does not stop the run.
login="$(gh config get -h github.com user)"
[ -n "$login" ] || { echo "ERROR: gh has no stored login" >&2; exit 1; }
pulse_slugs=" "

# set_repo_fields <slug> <base-branch>: generator opt-out and PR base branch, written atomically.
set_repo_fields() {
  local tmp
  tmp="$(mktemp "$REPOS_JSON.XXXXXX")"
  jq --arg s "$1" --arg b "$2" '
    .initialized_repos |= map(
      if .slug == $s then
        .dependabot_alert_monitor = false
        | (if $b == "" then del(.pr_base_branch) else .pr_base_branch = $b end)
      else . end)' "$REPOS_JSON" > "$tmp"
  mv "$tmp" "$REPOS_JSON"
}

# ensure_labels <slug>: on a repo the account can push to, aidevops' label helper creates its label set when
# auto-dispatch is missing; ensure then warns when that label still cannot be confirmed.
ensure_labels() {
  [ "$(gh api "repos/$1" --jq .permissions.push)" = true ] || return 0
  gh api "repos/$1/labels/auto-dispatch" >/dev/null 2>&1 && return 0
  echo "-- creating aidevops labels on $1 --"
  bash "$LABEL_HELPER" sync --repo "$1"
  bash "$LABEL_HELPER" ensure "$1" auto-dispatch \
    || echo "WARNING: labels on $1 not confirmed (rate limit or access); the next run tries again" >&2
}

for entry in $REPOS; do
  IFS=: read -r slug flag base <<< "$entry"
  if [ "$flag" != pulse ]; then base="$flag" flag=""; fi
  owner="${slug%%/*}"
  name="${slug#*/}"
  if [ "$owner" = "$login" ]; then path="$HOME/Git/$name"; else path="$HOME/Git/$owner/$name"; fi
  if [ ! -d "$path/.git" ]; then
    mkdir -p "$(dirname "$path")"
    gh repo clone "$slug" "$path"
  fi
  registered=0
  if [ -f "$REPOS_JSON" ]; then
    registered="$(jq --arg p "$path" '[.initialized_repos[]? | select(.path == $p)] | length' "$REPOS_JSON")"
  fi
  if [ "$registered" = 0 ]; then
    "$AIDEVOPS" repos add "$path" --slug "$slug" --confirm REGISTER_CANONICAL_REPOSITORY
  fi
  if [ "$flag" = pulse ] && [ "$PULSE" = on ]; then
    "$AIDEVOPS" repos pulse on "$slug"
    pulse_slugs="$pulse_slugs$slug "
  else
    "$AIDEVOPS" repos pulse off "$slug"
  fi
  set_repo_fields "$slug" "${base:-}"
  ensure_labels "$slug"
done

# A repo no longer marked :pulse stops, and stays cloned.
if [ -f "$REPOS_JSON" ]; then
  while read -r slug; do
    [ "$slug" = "$UPSTREAM_SLUG" ] && continue
    case "$pulse_slugs" in *" $slug "*) ;; *) "$AIDEVOPS" repos pulse off "$slug" ;; esac
  done < <(jq -r '.initialized_repos[] | select(.pulse == true) | .slug' "$REPOS_JSON")
fi

# ---- instructions repository: kept current, its files loaded by every OpenCode session ----------------
# Runs after setup.sh, which rewrites opencode.json but keeps the entries it finds in `instructions`.
if [ -n "$INSTRUCTIONS_REPO" ]; then
  instr_path="$HOME/Git/$INSTRUCTIONS_REPO"
  if [ ! -d "$instr_path/.git" ]; then
    mkdir -p "$(dirname "$instr_path")"
    gh repo clone "$INSTRUCTIONS_REPO" "$instr_path"
  else
    git -C "$instr_path" pull --ff-only
  fi
  opencode_json="$OPENCODE_JSON"
  for file in $INSTRUCTIONS_FILES; do
    [ -f "$instr_path/$file" ] || { echo "ERROR: $instr_path/$file does not exist" >&2; exit 1; }
    tmp="$(mktemp "$opencode_json.XXXXXX")"
    jq --arg p "$instr_path/$file" '
      .instructions = ((.instructions // [] | if type == "array" then . else [.] end)
        | if index($p) then . else . + [$p] end)' "$opencode_json" > "$tmp"
    mv "$tmp" "$opencode_json"
  done
fi
