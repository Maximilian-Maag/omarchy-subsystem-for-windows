# Changelog

## [0.1.0] - 2026-11-24

### Added

- The Windows VM engine as an installable Omarchy plugin: `omarchy-subsystem-for-windows`
  with `install`, `create`, `config`, `instances`, `launch`, `stop`, `status`, `remove`
  and `help`.
- One VM per named instance. The default instance keeps the historical
  `~/.windows` / `~/Windows` layout and port pair; named instances get their own
  storage, compose file, lock, ports and container name.
- `instances --json` for scripts and panels.
- `install.sh` copies the engine into `$PREFIX/bin` (default `/usr/local/bin`) as a
  root-owned file, because the privileged re-exec refuses symlinks. `--uninstall`
  removes only an unmodified copy.
- Shell suites for the compose/mount boundary, instance layer, launch/RDP
  readiness, readiness probing and installation; mutation testing over the engine.
