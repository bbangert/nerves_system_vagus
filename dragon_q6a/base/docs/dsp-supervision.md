# DSP daemon supervision

The system SHIPS the fastrpc daemons (`adsprpcd`, `cdsprpcd`, in
`/usr/sbin`) but does NOT start or supervise them — there is no init system on Nerves. Supervision is
app-level: start them from your OTP application (e.g. with
[MuonTrap](https://hex.pm/packages/muontrap)) so restarts, backoff, and
shutdown ride the app's supervision tree. Note the daemons serve root-PD
exception logging and remote file access; plain `fastrpc_test`-style
unsigned-PD offload works without them.

```sh
DSP_LIBRARY_PATH="/usr/lib/dsp/cdsp;" cdsprpcd &
ADSP_LIBRARY_PATH="/usr/lib/dsp/adsp;" adsprpcd &
```

Bare names resolve because `/usr/sbin` is on erlinit's default `PATH`. A
supervisor that spawns them by absolute path must use `/usr/sbin/…`:
fastrpc up to v1.0.5 installed them to `/usr/bin`.
