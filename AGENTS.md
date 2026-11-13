# Rules for this repository

- Do not add host access: no Incus remote back to the host, no shared folders, no SSH. The host drives the VM with
  `incus exec` only.
- Do not add bench or test-farm tooling.
- Secrets never go in argv, in a committed file or in a log. The GitHub token is piped on stdin from a host file that
  is refused when missing or readable by group or others. Model sign-ins stay interactive inside the VM.
- Every committed file stays generic: no real owner, org, repo, account, host or path of a person. Examples use
  placeholders such as `example-owner/repo`; real values live in the gitignored `.env`.
- Every step is idempotent and checks state first.
- Configuration changes go through the `guest/` scripts, which run on every `aidevops-vm.sh` run. cloud-init runs once
  and only prepares `/home` and the marker.
- `/home` is a volume that `up` and `rebuild` never delete.
- Run `tests/check.sh` before a commit.
