# dd-client

Native DevOps Defender clients.

This repo owns client-side code that should not live in
[`devopsdefender/dd`](https://github.com/devopsdefender/dd):

- `dd-client-core`: reusable Rust client core for pairing, quote verification,
  direct agent Noise transport, session RPCs, and PTY streaming.
- `dd-client`: CLI binary using `dd-client-core`.
- `dd-client-ffi`: C-compatible bridge for mobile transcript viewing.
- `apps/ios`: iOS companion that opens desktop-generated session links.

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

Open a shell:

```bash
DD_ITA_API_KEY=... dd-client shell \
  --url https://agent.example.com \
  --key ~/.config/devopsdefender/noise.key \
  --recipe shell
```

During an attached shell, `Ctrl-]` detaches and leaves the remote session alive.
`Ctrl-D` sends EOF to the remote shell and disconnects the local client. Use
`dd-client close --id SESSION_ID ...` to terminate a session explicitly.

Send a running session to the mobile companion app:

```bash
dd-client mobile-link \
  --url https://agent.example.com \
  --key ~/.config/devopsdefender/noise.key \
  --id SESSION_ID
```

Open the printed `devopsdefender://session?...` link on iOS, or render it as a
QR code with the printed `qrencode` command. The link includes the Noise private
key so the mobile app can import it before loading history and following the
live transcript; treat that link or QR code as secret.

Quote verification is on by default. Local preview/dev runs without Intel Trust
Authority credentials must pass `--insecure-skip-quote-verify` explicitly.
