# WiFi / Bluetooth (onboard AIC8800D80)

The board's Quectel FCU760K module (AIC8800D80, USB `a69c:8d80`) is
driven by the out-of-tree Aicsemi driver Radxa packages, built here as
two Buildroot packages pinned to the same commit:

- `package/aic8800` — the kernel modules. `aic_load_fw` uploads firmware
  (after which the chip re-enumerates as `a69c:8d81`), `aic8800_fdrv`
  presents **`wlan0`** (cfg80211 fullmac), `aic_btusb` presents **`hci0`**.
- `package/aic8800-firmware` — the proprietary blobs, installed to
  `/lib/firmware/aic8800D80/` (the path the loader actually opens).

Two non-obvious build rules live in `package/aic8800/aic8800.mk`, both
worth reading before touching the package:

1. **The raw upstream tarball does not build against this kernel.** Every
   kernel-compat fix lives in Radxa's `debian/patches/` quilt series
   (applied only by `dpkg-source` when they build their DKMS debs), so
   the package replays that series in series-file order. Two patches are
   deliberately skipped because the vendor SDK drop gave some `.c` files
   CRLF endings that the LF patches cannot apply to; neither is needed.
2. **`CONFIG_BLUEDROID` is flipped 1 → 0.** The vendor default exposes an
   Android-HAL character device instead of registering a BlueZ HCI —
   this is the root cause of every public "AIC8800 Bluetooth doesn't work
   on Linux" report. Radxa ship the same flip as a debian-only patch.

`BR2_PACKAGE_WIRELESS_REGDB=y` is **mandatory**, not cosmetic: this
kernel sets `CFG80211_REQUIRE_SIGNED_REGDB=y`, so without
`regulatory.db(.p7s)` cfg80211 fails the regdb load and the STA is stuck
in a restrictive world domain.

## BLE advertising needs a fast interval (device-proven trap)

This system ships no BlueZ userland. Whatever layer adds it must also ship
an `/etc/bluetooth/main.conf` with
`[LE] MinAdvertisementInterval=100` / `MaxAdvertisementInterval=150`
(BlueZ reads these in 0.625 ms slots → ~62.5–93.75 ms):

```ini
[LE]
MinAdvertisementInterval=100
MaxAdvertisementInterval=150
```

**Do not skip this.** At the kernel default (1280 ms), combined with BlueZ's
advertising-instance rotation, effectively no advertising events reach
the air — while every HCI command still returns status `0x00` and
`LEAdvertisingManager1.ActiveInstances` still reads 1. The failure is
completely silent from the host's point of view.

`package/aic8800/0001-aic-btusb-mask-broken-ext-adv-feature.patch.disabled`
is a parked wrong turn kept for the record: masking the LE Extended
Advertising *feature* bit does force legacy advertising, but
`use_ext_scan`/`use_ext_conn` key off the supported-**commands** bitmap
instead, so the kernel keeps issuing extended scan/connect commands and
that mix kills LE scanning outright on this firmware (0 devices vs 84).

## Status (device-proven 2026-07-25/26, kernel 7.1.4)

The Bluetooth rows ran with BlueZ 5.79 from the product layer.

On 2026-10-12, with kernel 7.2.10 and the `d13d079` driver, the WiFi scan
(2.4 and 5 GHz), BT adapter and BLE scanning rows were re-run; the other
rows were not.

| Capability | State |
|---|---|
| WiFi STA (`wlan0`) | **Works** — WPA2-PSK association, DHCP, data path; regdb loads, channels 1–165; 2.4 GHz and 5 GHz both proven |
| BT adapter (`hci0`) | **Works** — from the onboard chip on every boot, powered by bluetoothd 5.79 |
| BLE advertising (peripheral) | **Works** — Improv service advert received off-board at RSSI −13…−16 (needs the interval fix above) |
| BLE scanning (observer) | **Works** — 84–87 devices, passive AdvertisementMonitor and active discovery; steady across a multi-hour soak |
| WiFi + BLE coexistence | **Works** — scanning + advertising + an associated `wlan0`, concurrently, no interference |
| Inbound GATT (as peripheral) | **Works** — phone connected, resolved services, and completed a full Improv credential exchange |
| WPA3 / SAE association | **Works** — SAE handshake completes (`PMKSA-CACHE-ADDED` + `CTRL-EVENT-CONNECTED`), provisioned over Improv |

**Choose your test central carefully.** The inbound GATT result above came
from a phone. A Raspberry Pi 3's onboard BT 4.1 BCM43438 could *not*
connect to this board at all — every attempt ended in
`le-connection-abort-by-local` with no LE Meta / Connection Complete
event ever reaching the Q6A's HCI, which looks exactly like a firmware
that refuses `CONNECT_IND`. It isn't: a phone connects on the first try.
Do not conclude anything about this radio from a Pi-as-central test.

**WPA3 (SAE) works, including over Improv — but needs `improv >= 0.1.2`.**
Earlier versions hardcoded `key_mgmt: :wpa_psk`, so an SAE-only SSID
associated and then failed the 4-way handshake, surfacing as a misleading
"wrong password" ([bbangert/improv#2](https://github.com/bbangert/improv/issues/2)).
0.1.2 infers SAE vs PSK from the target SSID's live scan flags.

Device-proven on this board: provisioned onto an SAE-only network from a
phone, producing `key_mgmt: :sae` with `ieee80211w: 2` and a completed
handshake (`PMKSA-CACHE-ADDED` → `Associated` → `CTRL-EVENT-CONNECTED`).

**Provisioning trap that survives that fix:** the SAE inference reads the
*live* `access_points` property and never triggers a scan of its own. A
device waiting to be provisioned has no configured networks, so
wpa_supplicant is not background-scanning and that property can be empty
exactly when Improv needs it — in which case the inference silently falls
back to PSK and an SAE-only network fails as before. Observed here: the
first attempt fell back to PSK, and only a `VintageNet.scan("wlan0")`
seconds before submitting made it pick SAE. If you are debugging a failed
WPA3 provision, check the applied `key_mgmt` before suspecting the radio.

To put the board on an SAE-only network by hand, `vintage_net_wifi`
supports it directly:

```elixir
VintageNet.configure("wlan0", %{
  type: VintageNetWiFi,
  vintage_net_wifi: %{
    networks: [%{key_mgmt: :sae, ssid: "...", sae_password: "...", ieee80211w: 2}]
  },
  ipv4: %{method: :dhcp}
})
```

`ieee80211w: 2` (management-frame protection required) is mandatory for
WPA3 — omit it and the association fails.

Kernel-config note: `linux-7.2.defconfig` sets `CONFIG_IP_ADVANCED_ROUTER`
+ `CONFIG_IP_MULTIPLE_TABLES` for the radio. `vintage_net`'s
RouteManager hard-requires policy routing — without it every `set_route`
fails with RTNETLINK "Operation not supported", RouteManager crash-loops,
and the whole `vintage_net` application goes down (which an ethernet-only
board never notices, because ssh keeps working).

## USB Bluetooth dongles

`BR2_PACKAGE_LINUX_FIRMWARE_RTL_87XX_BT` ships the Realtek `rtl_bt` blobs.
A TP-Link UB500 (RTL8761BU) is device-proven: it enumerated, btusb loaded
the firmware, and the adapter powered on and was discoverable over the air.
BlueZ cancels discovery when the requesting D-Bus client disconnects, so
inbound scanning needs a persistent client (e.g. the `bluez` hex library),
not one-shot `dbus-send` calls.
