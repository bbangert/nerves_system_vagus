# nerves_system_vagus

Custom Nerves systems for the Universal Proxy project — forks of the upstream
`nerves_system_*` systems with our additions (Bluetooth via **BlueZ + D-Bus**,
and USB-audio for USB DACs). One repo, one system per target subdirectory,
built in CI so consumers never need a local buildroot toolchain.

## Layout

```
.
├── shared/
│   └── linux-bluetooth.config  # canonical kernel fragment (edit here → make sync)
├── rpi0/  rpi0_2/  rpi3/  rpi4/  rpi5/   # one Mix project per BT-capable target
│   ├── mix.exs                 #   artifact_sites → THIS repo's Releases
│   ├── nerves_defconfig        #   + BlueZ/D-Bus + firmware pkgs + kernel fragment ref
│   └── linux-bluetooth.config  #   synced copy (referenced by the build)
├── Makefile                    # `make sync` / `make check`
└── .github/workflows/build.yml # matrix build → GitHub Releases
```

Targets covered: **rpi0** (Zero W), **rpi0_2** (Zero 2 W), **rpi3** (3A+/3B/3B+/CM3),
**rpi3_64** (3A+/3B/3B+, 64-bit), **rpi4** (4B/400/CM4), **rpi5**. `rpi`/`rpi2` have
no onboard Bluetooth.

Each target subdir is a **self-contained Nerves system** (its own
`nerves_defconfig`, `fwup.conf`, overlay, and a local copy of any shared
fragment). Self-containment is required so the main project can pull a single
target via a git `sparse:` dep and so artifact checksums stay correct.

## The shared-fragment workflow

`shared/*.config` are the source of truth. Each target references a **local
copy** (e.g. `rpi3/linux-bluetooth.config`) via
`BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` in its `nerves_defconfig`. After
editing anything under `shared/`:

```sh
make sync     # materialize copies into every target subdir
make check    # CI-friendly: fails if any copy drifted from shared/
git add -A && git commit
```

(We can't reference `../shared` directly from a target, because a `sparse:`
checkout only fetches that one subdir and the artifact checksum only covers
subdir-local files.)

## Controller firmware (via the nerves_system_br package — no vendored blobs)

Each target's `nerves_defconfig` enables **`BR2_PACKAGE_RPI_DISTRO_BLUEZ_FIRMWARE=y`**,
a nerves_system_br package that installs the Broadcom BT patchram set
(`BCM43430A1/B0`, `BCM4345C0/C5`) **plus the board-specific symlinks `btbcm`
requests first** (`BCM4345C0.raspberrypi,3-model-b-plus.hcd`, etc.) and the Pi
Zero 2 W **Synaptics** blobs — to `/lib/firmware/brcm/`. The stock image ships
only WiFi `brcmfmac` firmware and BlueZ (the host stack) carries no controller
firmware, so this package is what lets the kernel bring up the radio. (rpi5
already enabled it upstream.) No `.hcd` is committed to this repo — the package
fetches them at build time and gets the board mapping right for us.

## Adding another target

Same recipe as the existing five:
1. Copy the upstream system into a new subdir (drop `.git`/`hex_metadata.config`).
2. `mix.exs`: `@github_organization "bbangert"`, add `@releases_repo` +
   `{:github_releases, @releases_repo}` in `artifact_sites`, add
   `"linux-bluetooth.config"` to `package_files()`, set `VERSION` to `0.1.0`.
3. `nerves_defconfig`: add the `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` line +
   `BR2_PACKAGE_DBUS=y` / `BR2_PACKAGE_BLUEZ5_UTILS=y` /
   `BR2_PACKAGE_RPI_DISTRO_BLUEZ_FIRMWARE=y`.
4. Add it to `TARGETS` (Makefile) + `matrix.target` (build.yml), then `make sync`.

## How CI publishes, and how the project consumes it

- Push a tag `vX.Y.Z` → the `build` job compiles each target's artifact and
  uploads it to that tag's **GitHub Release**.
- In `universal_proxy`'s `mix.exs`, point the customized target(s) at this repo
  (a git dep with `sparse:` selects the subdir; `override: true` replaces the
  upstream hex system):

  ```elixir
  {:nerves_system_rpi3, github: "bbangert/nerves_system_vagus",
     sparse: "rpi3", tag: "v0.1.0", runtime: false, targets: :rpi3, override: true},
  ```

- `mix deps.get && mix deps.compile` then **downloads the prebuilt artifact**
  (matched by app-name + checksum from `artifact_sites`) into `~/.nerves` — no
  local buildroot. Leave non-customized targets on their upstream hex systems.

### Caveats
- **Host arch:** artifacts are per-host. CI builds the **linux/x86_64**
  artifact — consume it from a linux/x86_64 host (or build firmware in CI too).
  An Apple-Silicon Mac can't use the x86_64 artifact and would fall back to a
  (failing, toolchain-less) local build.
- **Checksum discipline:** every change to a system's source must be rebuilt &
  republished (new tag) or `mix deps.compile` won't find a matching artifact
  and will try to build locally. Pin by `tag:`, not `branch:`.
- **Private repo:** consuming Release assets from a private repo needs a token.

## Not in this repo: the `bluetoothd` startup + D-Bus client

Bringing up `dbus-daemon` + `bluetoothd` at runtime, and talking to
`org.bluez` (via the `rebus` Elixir D-Bus client), lives in the **application**
(`universal_proxy`), not in the system image — because Nerves uses `erlinit`,
not systemd. Plan: a small supervisor that launches both daemons (e.g. via
`MuonTrap.Daemon`) with writable state on `/root` (machine-id,
`/var/lib/bluetooth`), then the BT supervision tree connects to the system bus.
