# DSP daemon supervision

The system ships the fastrpc daemons but does not start or supervise them;
there is no init system on Nerves. Start them from your OTP application
(e.g. with [MuonTrap](https://hex.pm/packages/muontrap)) so restarts,
backoff and shutdown ride the app's supervision tree:

```sh
DSP_LIBRARY_PATH="/usr/lib/dsp/cdsp;" cdsprpcd &
ADSP_LIBRARY_PATH="/usr/lib/dsp/adsp;" adsprpcd &
```

Bare names resolve because `/usr/sbin` is on erlinit's default `PATH`.
