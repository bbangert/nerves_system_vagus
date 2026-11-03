# Audio playback

The mixer powers up with the entire headphone path disconnected/muted.
The validated `amixer -c 0 cset` sequence (runtime state — apply from the
application at boot; `alsactl` is not shipped):

```sh
# frontend -> codec-DMA backend
amixer -c 0 cset name='RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1' 1
# rx-macro: RX0/RX1 from AIF1, interpolators CONNECTED (default is ZERO!)
amixer -c 0 cset name='RX_MACRO RX0 MUX' AIF1_PB
amixer -c 0 cset name='RX_MACRO RX1 MUX' AIF1_PB
amixer -c 0 cset name='RX INT0_1 MIX1 INP0' RX0
amixer -c 0 cset name='RX INT1_1 MIX1 INP0' RX1
amixer -c 0 cset name='RX INT0_1 INTERP' 'RX INT0_1 MIX1'
amixer -c 0 cset name='RX INT1_1 INTERP' 'RX INT1_1 MIX1'
amixer -c 0 cset name='RX INT0 DEM MUX' CLSH_DSM_OUT
amixer -c 0 cset name='RX INT1 DEM MUX' CLSH_DSM_OUT
amixer -c 0 cset name='RX_COMP1 Switch' 1
amixer -c 0 cset name='RX_COMP2 Switch' 1
# wcd938x: DAC/PA path + Class-H mode (default CLS_H_INVALID = silence!)
amixer -c 0 cset name='HPHL_RDAC Switch' 1
amixer -c 0 cset name='HPHR_RDAC Switch' 1
amixer -c 0 cset name='HPHL Switch' 1
amixer -c 0 cset name='HPHR Switch' 1
amixer -c 0 cset name='HPHL_COMP Switch' 1
amixer -c 0 cset name='HPHR_COMP Switch' 1
amixer -c 0 cset name='RX HPH Mode' CLS_H_LOHIFI
# volumes (DSP stream volume defaults low; digital 84 = 0 dB)
amixer -c 0 cset name='stream0.vol_ctrl0 MultiMedia1 Playback Volu' 100%
amixer -c 0 cset name='RX_RX0 Digital Volume' 84
amixer -c 0 cset name='RX_RX1 Digital Volume' 84
amixer -c 0 cset name='HPHL Volume' 20
amixer -c 0 cset name='HPHR Volume' 20
```

Then `aplay -D hw:0,0 file.wav` (48 kHz S16_LE stereo; use `plughw` for
other formats). The two silent traps: `RX INT*_1 INTERP` defaults to
`ZERO` and `RX HPH Mode` defaults to `CLS_H_INVALID` — each alone mutes
program audio while still passing transient clicks.

Playback through the headphone jack (WCD938x) is device-proven with this
recipe; capture is unvalidated. Expected, cosmetic dmesg lines: soundwire
`cgcr reset` + `din/dout-ports mismatch`, and an occasional MBHC
`Impedance detect ramp error` on unusual jack loads.
