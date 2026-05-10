# dd-client

Native DevOps Defender clients.

This repo owns client-side code that should not live in
[`devopsdefender/dd`](https://github.com/devopsdefender/dd):

- `dd-client-core`: reusable Rust client core for pairing, quote verification,
  direct agent Noise transport, session RPCs, and PTY streaming.
- `dd-client`: CLI binary using `dd-client-core`.
- `apps/native`: native app workspace placeholder; it will use the same core.

The control plane is only for enrollment and route discovery. Shell, log, and
session bytes go directly between the paired client and the selected agent over
Noise.

## Build

```bash
cargo build
```

## CLI

Generate a paired device key and print the CP enrollment URL:

```bash
dd-client keygen --key ~/.config/devopsdefender/noise.key \
  --cp-url https://app.devopsdefender.com \
  --label laptop
```

List recipes on an enrolled agent:

```bash
DD_ITA_API_KEY=... dd-client recipes \
  --url https://agent.example.com \
  --key ~/.config/devopsdefender/noise.key
```

Open a shell:

```bash
DD_ITA_API_KEY=... dd-client shell \
  --url https://agent.example.com \
  --key ~/.config/devopsdefender/noise.key \
  --recipe shell
```

Quote verification is on by default. Local preview/dev runs without Intel Trust
Authority credentials must pass `--insecure-skip-quote-verify` explicitly.

