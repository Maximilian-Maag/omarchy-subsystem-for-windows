# Architecture

The plugin is one bash engine (`bin/omarchy-subsystem-for-windows`) plus an
installer. Every invariant below names the test that proves it.

## The privilege boundary

**The compose file is root-owned and written only by the elevated writer.**
`write_compose` always elevates; the user-side command never writes into the
runtime directory. The privileged writer validates every value again, because the
user-side prompt and the root-side writer are separate processes and the argument
list crosses the boundary. `tests/shell/test_windows_vm_compose.sh` drives the
writer and asserts the produced YAML.

**The elevated target is a regular root-owned file.** `priv_target()` accepts only
an installed file that is not a symlink, whose canonical path equals its own path,
and whose ancestors are root-owned and not group- or world-writable. A PATH shim or
a dev checkout is refused. `tests/shell/test_windows_vm_compose.sh` hides the
installed candidates and asserts that a PATH symlink cannot become the target.

**Mount anchors are validated, not trusted.** The container's storage and shared
folders are bind-mounted from the caller's home; the writer refuses a path that is
a symlink, a mount point, or outside the expected pair, and removal proves there
are no bind aliases before deleting anything. `test_windows_vm_compose.sh` and
`test_windows_vm_mount_boundary.sh` cover the writer and the EUID-0 boundary.

## Instances

**One VM per instance, and every derived path follows the name.** An instance name
selects the runtime directory, compose file, container name, Docker project, port
pair, lock directory and storage folders. The default instance keeps the historical
layout so an install created before instances existed still matches.
`tests/shell/test_windows_vm_instances.sh` checks name validation, the derived
paths and ports, and the read-only listing.

**A name is a path, a container name and a lock name.** It is validated as
`^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$` on the user side and again in the
privileged writer. `test_windows_vm_instances.sh` rejects dots, slashes, uppercase
and leading or trailing hyphens.

## Launch

**A session that connected stops the VM; a session that never connected leaves it
running.** FreeRDP exits 0 for a closed window and 2, 4 or 12 for a logoff or the
server's session limit: those mean the session connected. Denied connections,
credential failures and transport errors never connected. `test_windows_vm_launch.sh`
covers both sets, and the readiness timeout reports "still booting" without
stopping the VM.

**A launch without a terminal still reports failure.** A launcher (desktop entry,
keybinding) has no terminal to print into, so the failure goes through
`omarchy-notification-send`. `test_windows_vm_launch.sh` asserts the notification.

## Networking

**An internet-off instance cannot reach the network.** The container is attached to
a dedicated bridge with masquerading disabled, so the guest reaches the host's
published web console and RDP port but nothing beyond. The toggle recreates the
container's network attachment, which is a restart, not a live switch.
`test_windows_vm_compose.sh` asserts the network block in the compose.

## Installation

**The engine is copied, not symlinked.** `install.sh` copies the engine to
`$PREFIX/bin` and `--uninstall` removes only a copy identical to the checkout, so a
modified copy is reported and left alone. `tests/shell/test_install.sh` covers the
copy, idempotence and both uninstall paths.

## Audio

**Guest audio only reaches the host when the instance has a sound device and the
client names a real backend.** Both halves are required and neither is implicit:

- The image attaches an HDA device only when `AUDIO=Y` is in the container
  environment, so the engine writes it from the instance's `audio` setting and
  omits it entirely when the setting is off. A guest without the device produces
  no audio to redirect, however the client is configured.
- FreeRDP's bare `/sound` resolves to its fake backend on this build: the channel
  opens, the guest plays, and nothing is heard. The launch arguments therefore say
  `/sound:sys:alsa`, which reaches the host through PipeWire's ALSA bridge.

The device the image attaches is `hda-output`: output only. Microphone
redirection is sent (`/microphone:sys:alsa`) but has no capture endpoint to read
from until the guest is given a duplex device, so it is documented as silent
rather than advertised as working.

`test_windows_vm_accel.sh` asserts the compose carries `AUDIO: "Y"` when the
setting is on and omits it when off; `test_windows_vm_launch.sh` asserts the
client receives the ALSA flags.

## What is not covered here

A real Windows guest boot, RDP window and GPU/PCI passthrough are not exercised by
the suite. The tests stop at the compose boundary and at stubbed `docker` and
`xfreerdp3`; a real boot needs a host with KVM and a downloaded Windows image.
