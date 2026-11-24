# Subsystem for Windows

Windows as a KVM guest inside a privileged Docker container, managed from the
Omarchy desktop. One VM per named instance, each with its own disk, ports, network
and settings. This repository packages the engine as an Omarchy plugin.

Plugin id: `Maximilian-Maag.subsystem-for-windows`.

## Install

```bash
git clone <this repo> ~/Work/omarchy-subsystem-for-windows
cd ~/Work/omarchy-subsystem-for-windows
./install.sh
```

Or let the plugin manager do it:

```bash
omarchy plugin add <repo-url> --yes
```

`install.sh` validates the manifest and copies the engine to
`/usr/local/bin/omarchy-subsystem-for-windows` as a root-owned file. The copy is
deliberate: every privileged action re-executes the command through `pkexec`, and
that path refuses a symlink or anything a non-root user could have written. Re-run
`./install.sh` after `git pull`.

## Requirements

- An x86_64 machine with KVM (the guest is x86_64).
- Docker with the compose plugin, and polkit for the elevation prompt.
- `xfreerdp3` for the RDP window. `install` adds `freerdp`, `openbsd-netcat` and
  `gum` through `omarchy-pkg-add` when they are missing.

The command refuses to run on a non-x86_64 host before it defines anything.

## Commands

```bash
omarchy-subsystem-for-windows install                  # set up the default VM
omarchy-subsystem-for-windows create work --version 11 --ram 8G --cores 4
omarchy-subsystem-for-windows create offline --no-internet --start
omarchy-subsystem-for-windows instances [--json]       # list the VMs
omarchy-subsystem-for-windows config work ram=16G      # change a setting
omarchy-subsystem-for-windows launch work              # start if needed, connect
omarchy-subsystem-for-windows stop work
omarchy-subsystem-for-windows status work
omarchy-subsystem-for-windows remove work
```

`launch` starts the VM when it is not running, waits for the RDP port, and opens
the session. A session that connected but ended (window closed, logoff, session
limit) stops the VM; a connection that never succeeded leaves the VM running and
says so. `--keep-alive` leaves the VM running after the session ends.

## Runtime layout

The plugin shares the runtime namespace with the core `omarchy-windows-vm`
command, so either one manages the same VMs:

| Path | Purpose |
| --- | --- |
| `/var/lib/omarchy/windows/docker-compose.yml` | default instance compose (root-owned) |
| `/var/lib/omarchy/windows/instances/<name>/` | named instance compose and settings |
| `~/.windows`, `~/Windows` | default instance disk and shared folder |
| `~/.config/windows/credentials` | private 0600 copy of the guest password |
| `/run/lock/omarchy-windows-vm` | per-instance lock directory |

Install one of the two commands, not both on `PATH` at once: they would fight over
the same container names.

## Security model

The compose file is root-owned and written only by the elevated, input-validated
`write_compose` action. A root-invoked `docker compose up` must never consume a
file a user process could rewrite into a bind mount of `/`. Values that reach the
compose (version, RAM, cores, disk, ports, username, timezone, password, USB
pairs) are validated on the user side and again in the privileged writer.

The engine re-executes itself through `pkexec` after checking that the target is a
regular, root-owned file whose ancestors are not group- or world-writable. An
instance name is a directory, a container name, a Docker project name and a lock
directory, so it is deliberately narrow: lowercase letters, digits and hyphens.

## Tests

```bash
make test          # policy, shell suites, mutation
make check         # policy + two fast suites
SKIP_MUTATION=1 make test
```

The shell suites drive the real engine with stubbed `docker`, `pkexec` and
`xfreerdp3`. The mount-boundary suites run in an unprivileged user namespace and
skip when one is unavailable.

## Layout

```
bin/omarchy-subsystem-for-windows   the engine (one bash script)
install.sh                          validate + copy the engine onto PATH
manifest.json                       plugin manifest (kind: cli)
policy.json                         policy as code, test kinds, mutation floor
tests/shell/                        shell suites
tests/mutation.json                 mutation targets and exemptions
tools/                              run_tests.sh, policy_check.py, mutator.py
docs/architecture.md                the invariants and the test that proves each
```
