# The launch voice: Kokoro-82M, locally

Holograph speaks each launch — "Opening Truebearing" — with a voice that runs
entirely on the iPad. This note says exactly what the neural voice is, where the
model lives, and what has to be done to provision it.

> **The voice works without any of this.** Speech is layered: `LayeredSpeech`
> prefers Kokoro and falls back to the system's British voice, so a fresh
> install speaks the first time it is asked to with nothing downloaded and
> nothing switched on. Everything below is about the *better* voice, not about
> whether there is one. See "Speech is layered" in the README.

## What is used

| | |
|---|---|
| Model | **Kokoro-82M** |
| Licence | **Apache License 2.0** (weights and code) |
| Voice | **`bm_george`** — British male |
| Speech rate | 0.94 |
| Runtime | **Core ML** (`MLModel`), compute units `.all` |
| Sample rate | 24 kHz, mono |
| Network at synthesis | **none** |

The voice is chosen for the character the launcher wants: calm, level,
unhurried, a shade deep. It is a Holograph voice. Nothing here clones, imitates,
trains on or attempts to reproduce any real person.

## What is in this repository, and what is not

**`bm_george.bin` is committed** — 522,240 bytes, the 510 × 256 style block —
and ships in the app bundle. It is small enough to belong here.

**The Core ML weights are not**, for a reason that is specific rather than
stylistic: the smallest useful Kokoro-82M export is about 160 MB, and GitHub
refuses any single file over 100 MB. Committing it would mean sharding it into
ten parts and reassembling them in a build phase, which puts a step that can
fail between every clone and a working build. So the repository contains the
**integration**, and the model is provisioned separately. `HolographTests`
exercises the whole speech path against `StubNeuralSpeech`; the real model is a
device concern.

### Where the weights can be got

The upstream weights live on Hugging Face
(`hexgrad/Kokoro-82M`, and `onnx-community/Kokoro-82M-v1.0-ONNX` for the ONNX
export), Apache-2.0 in both cases. The ONNX export is also republished on npm as
`kokoro-fp16-shards` (163 MB across ten parts, Apache-2.0), which is useful in
environments where Hugging Face is unreachable.

Getting from there to `Kokoro.mlmodelc` still needs a conversion pass — the ONNX
graph uses `STFT`, `NonZero` and six `LSTM`s, none of which map cleanly onto
Core ML MIL, so the practical route is the PyTorch source through
`coremltools`, splitting the vocoder out as its own model. `mattmireles/kokoro-coreml`
is a working pipeline for exactly that. **Whatever route is used, the resulting
`.mlpackage` must be verified on a real device before it ships** — a model that
loads but decodes wrongly is worse than no model, because the fallback would
have spoken.

## Where the app looks

`KokoroModelStore` checks two places, in order:

1. **The app bundle** — `Kokoro.mlmodelc` and `bm_george.bin`, for a build that
   ships the model inside it.
2. **`Application Support/Kokoro/`** — the same two files, for a build that
   provisions them after installing.

Both are read from disk. Neither path involves the network.

If either file is missing, `KokoroSpeechEngine.isReady` is `false`,
`unavailableReason` records which piece is missing, and `LayeredSpeech` moves on
to the system voice — so the user hears a launch announced either way and
Settings shows nothing. **The launcher behaves exactly as it otherwise would.**
A spoken launch is a decoration and is never allowed to become a dependency;
Settings only ever reports a problem when *nothing* on the iPad can speak.

## Files expected

| File | What it is |
|---|---|
| `Kokoro.mlmodelc` | The Core ML model, **compiled** — the `.mlmodelc` directory produced by `xcrun coremlcompiler compile Kokoro.mlpackage <out>`, or by adding the `.mlpackage` to the Xcode target |
| `bm_george.bin` | The voice's style vector: a flat little array of 32-bit floats |

The model is expected to take `input_ids` (int32 token ids) and `style`
(float32), optionally `speed`, and to return a float waveform.
`KokoroSynthesis.render` checks those inputs are present and returns `nil`
rather than guessing if the model's interface is not the one this was written
against — a model file that is not the right one should produce silence and a
log line, never noise.

## Provisioning

Two supported routes:

**Bundle it.** Add `Kokoro.mlpackage` and `bm_george.bin` to the Holograph
target. Xcode compiles the package to `Kokoro.mlmodelc` at build time and
`KokoroModelStore` finds it in the bundle with no further work. This makes the
IPA larger but means the voice works on first run with nothing to download.

**Provision after install.** Place the two files in
`Application Support/Kokoro/` on the device. Nothing in the app fetches them: a
download is deliberately *not* implemented here, so that no build of Holograph
ever contacts a host this repository cannot verify.

Either way the transition is silent from the user's side. Before provisioning
the system voice speaks; afterwards Kokoro does; nothing has to be enabled and
no setting changes.

## Licence obligations

Kokoro-82M is Apache-2.0. A build that ships the weights must include the
Apache-2.0 licence text and the model's attribution notice in the app bundle and
surface them where the app's other notices are shown. The `README` records the
dependency; the licence file itself belongs alongside the weights whenever they
are added.

## Verifying on a device

Once provisioned:

1. Settings → Sound → **Say the App Name** is on.
2. Open the app; the engine warms in the background once the launcher is usable.
3. Tap a tile. The first announcement may arrive slightly late if it was not
   pre-rendered; every subsequent one is instant, from the cache. Check the log
   for `neural voice ready` rather than `system voice ready` — both speak, and
   the point of this exercise is to confirm *which* one did.
4. Rename a tile and open it again — it should say the new name.
5. Turn on clap-to-open and open something. The announcement must not trigger a
   clap; the listener is muted for the phrase's measured duration.
