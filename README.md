# aidevops-vm

One host script, `aidevops-vm.sh`, creates or repairs a Debian 13 Incus VM whose only job is
[aidevops](https://github.com/marcusquinn/aidevops) with OpenCode as its runtime.

- `/home` is its own Incus block volume. A rebuild replaces the operating system and keeps the aidevops install, the
  clones in `~/Git`, the gh, OpenCode and model-account logins, and aidevops' config and secrets.
- The VM updates itself. aidevops' systemd user timer updates aidevops and OpenCode; Debian's unattended-upgrades
  updates every apt package (gh and Node included) and restarts the VM at `REBOOT_TIME` when needed.
- The VM reaches the internet only. A NIC-level Incus ACL drops these destinations: IPv4 10.0.0.0/8, 172.16.0.0/12,
  192.168.0.0/16, 100.64.0.0/10 (tailnet), 169.254.0.0/16, 127.0.0.0/8, 0.0.0.0/8, 224.0.0.0/4 and 240.0.0.0/4; IPv6
  fc00::/7, fe80::/10 and ff00::/8; the host's global IPv4 addresses and its on-link IPv6 networks. It
  allows everything else and has no ingress rule. There is no SSH, no shared folder and no Incus remote: the host drives the VM with `incus exec`.
- The pulse runs unattended on the repos marked `:pulse` in `REPOS`, only on issues labelled `auto-dispatch`.

## First deploy

Needs Incus, `jq` and `ip` on the host.

1. Make a GitHub account for the VM, give it Write (never admin) on the repos it works, and create a classic personal
   access token with scopes `repo`, `read:org`, `gist`. Fine-grained tokens cannot span several owners or
   third-party repos. Without `workflow`, GitHub refuses any push that changes `.github/workflows/`, so workers
   cannot change CI.
2. Store the token in a file outside every repository with mode 0600.
3. `cp .env.example .env`, then set `GITHUB_TOKEN_FILE`, `GIT_USER_NAME`, `GIT_USER_EMAIL` and `REPOS`. The script
   refuses a missing or group- or other-readable token file.
4. `./aidevops-vm.sh`

`REPOS` entries are `owner/repo[:pulse[:base-branch]]`. Every repo is cloned and registered with `aidevops repos add`;
`aidevops init` is never run, so no aidevops file is added to a repo. `:pulse` turns the pulse on for the repo, and a
base branch (`owner/repo:pulse:dev`) makes workers open PRs against that branch. A repo without `:pulse` gets
registered with the pulse off. A repo removed from `REPOS` has its pulse turned off and stays cloned.

## One-time sign-ins

Model accounts are signed in by hand inside the VM; the script never handles those secrets and they persist on the
home volume.

    incus exec -t aidevops-vm -- su - debian

- OpenCode Go and OpenRouter: `opencode auth login`. Give the OpenRouter key a spending cap at openrouter.ai.
- Claude Pro or Max subscription: `aidevops model-accounts-pool add anthropic`. Anthropic's terms restrict subscription
  OAuth to Claude Code and Anthropic's own apps
  ([Authentication and credential use](https://code.claude.com/docs/en/legal-and-compliance)); using it through the
  account pool is at the account owner's risk.

## Operation

| Task | Command |
| --- | --- |
| Create, repair or apply a changed `.env` | `./aidevops-vm.sh` |
| Replace the operating system, keep `/home` | `./aidevops-vm.sh rebuild` |
| Delete the VM and the home volume (asks for the VM name) | `./aidevops-vm.sh reset-home` |
| Stop the pulse | `./aidevops-vm.sh pulse-stop` |
| Start the pulse again | `./aidevops-vm.sh pulse-start` |
| Verify timers, updates, linger, pulse and egress | `./aidevops-vm.sh check` |

`pulse-stop` holds across updates and across `./aidevops-vm.sh` runs until `pulse-start`. Setting `PULSE=off` disables
the pulse timer on the next run; setting it back to `on` enables it again, unless `pulse-stop` is in effect. For a hard stop, `incus stop aidevops-vm`.

Work starts when a person labels an issue `auto-dispatch`. `no-auto-dispatch`, `parent-task` and `hold-for-review`
block dispatch.

Every run re-applies the configuration in `guest/`: packages, unattended-upgrades, the aidevops config values, the
memory limit of the pulse unit, repo registration. The aidevops clone in `~/Git/aidevops` is owned by aidevops'
updater; the script clones it once and never touches it again. A Node major change is a `NODE_MAJOR` edit plus a
re-run.

Worker slots follow free memory: `(available RAM - RAM_RESERVE_MB - growth) / 1536 MB`, capped by `MAX_WORKERS`.

## What updates itself

- aidevops: `aidevops-auto-update.timer` (user timer, needs linger, which the script enables) pulls and redeploys it
  every ten minutes and rolls back a failed deploy.
- OpenCode: the same updater's six-hourly tool check, through npm.
- Everything apt: unattended-upgrades, including the GitHub CLI and NodeSource repositories.

See it with `./aidevops-vm.sh check`, or inside the VM `systemctl --user list-timers`, `aidevops auto-update status`,
`aidevops pulse status`.

## Known behaviour

- The pulse approves and merges ready PRs and closes conflicting ones on pulse repos. Required checks in branch
  rulesets, and an account without admin rights, are the brake.
- The token has `repo` scope on everything the account can reach; keep its access to Write grants.
- Issue generators: the Dependabot alert monitor is switched off per repo (`dependabot_alert_monitor: false`). The
  failure miner stays on: an hourly user timer (`aidevops-gh-failure-miner.timer`) files `auto-dispatch` issues for
  repeated CI failures on pulse repos, and the pulse then works them. The complexity scan only acts on the aidevops repository itself and only
  for a maintainer of it, so it stays idle here.
- aidevops may file issues in its own upstream repository under the account (its throughput throttle policy and
  contributor insights).
- Upstream releases several times a day; a bad release can reach the VM within ten minutes despite the rollback.
- The VM user has sudo inside the VM; the VM boundary and the egress ACL are the limits.
- Worktree creation needs 5 GiB and 5 % free disk; size `HOME_SIZE` for the repos.
