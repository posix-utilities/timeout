# [`timeout`](https://github.com/posix-utilities/timeout)

POSIX.1-2024 timeout

```sh
timeout [options] <duration> <command> [arguments...]
```

## Contents

- [Usage](#usage)
  - [Exit status](#exit-status)
- [Install](#install)
- [Build](#build)
  - [Go](#go)
    - [go build](#go-build)
    - [goreleaser](#goreleaser)
    - [monorel](#monorel)
  - [Zig](#zig)
    - [Windows behavior](#windows-behavior)

## Usage

```text
-f             send timeout signal to the proccess only, not the process group
               (when the group is sent the signal, 'timeout' briefly ignores it)
-k <duration>  kill the process with SIGKILL after duration (respects -f)
-p             preserve original exit status, regardless if timeout occured
-s <signal>    TERM by default, or the chosen signal

   <duration>  such as 10, 10s, 2.5m, 24h, or 1.5d
```

### Exit status

```text
0              no error (or no error from <command> with -p)
<n>            the return status of <command> (with -p)
124            if killed by timeout (if -p is NOT specified)
125            all other errors (if -p is NOT specified)
126            command not executable
127            command not found
```

## Install

Install the latest release:

```sh
curl https://webi.sh/timeout | sh
```

Browse releases at:

<https://github.com/posix-utilities/timeout/releases>

The archive contains the executable with its executable bit preserved, so
extracting it does not require a separate `chmod` step. Move the extracted
binary to `~/bin/` or another directory already in `PATH`. For example:

```sh
curl -fL -o timeout.tar.gz \
  'https://github.com/posix-utilities/timeout/releases/download/cmd/timeout/v1.0.0/timeout_1.0.0_Linux_x86_64.tar.gz'
tar -xzf timeout.tar.gz
mkdir -p ~/bin
mv ./timeout ~/bin/timeout
~/bin/timeout --version
```

# Build

## Go

### go build

Build a local Linux amd64 binary:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v2 \
  go build -o ./timeout-linux-unknown-x86_64 ./cmd/timeout/
mv ./timeout-linux-unknown-x86_64 ~/bin/timeout
```

Install Go if needed:

```sh
curl https://webi.sh/go | sh
source ~/.config/envman/PATH.env
```

### goreleaser

Install GoReleaser:

```sh
curl https://webi.sh/go | sh
source ~/.config/envman/PATH.env
webi goreleaser
```

To build and inspect all release artifacts without publishing:

```sh
(cd cmd/timeout/ && VERSION=0.0.0 goreleaser release --snapshot --clean)
```

### monorel

Install the complete release toolchain:

```sh
curl https://webi.sh/go | sh
source ~/.config/envman/PATH.env
webi goreleaser gh monorel
```

The Go command is an independently versioned module under `cmd/timeout/`.
Initialize its GoReleaser config and scoped tag the first time:

```sh
monorel init ./cmd/timeout/
```

Create a release interactively:

```sh
monorel release ./cmd/timeout/
```

The release build currently supports these targets:

| OS | Architectures |
| --- | --- |
| AIX | ppc64 |
| Android | arm64 |
| Darwin | amd64, arm64 |
| DragonFly | amd64 |
| FreeBSD | 386, amd64, armv6, armv7, arm64 |
| Illumos | amd64 |
| Linux | 386, amd64, armv6, armv7, arm64, loong64, ppc64, ppc64le, riscv64, s390x |
| NetBSD | 386, amd64, armv6, armv7, arm64 |
| OpenBSD | 386, amd64, armv6, armv7, arm64, ppc64, riscv64 |
| Solaris | amd64 |
| Windows | 386, amd64, arm64 |

## Zig

```sh
curl https://weib.sh/zig@v0.14 | sh
source ~/.config/envman/PATH.env

zig targets | jq -r ".libc[]" | sort -r
```

```sh
zig build-exe ./timeout.zig -O ReleaseSmall
mv ./timeout ~/bin/
```

```sh
zig build-exe ./timeout.zig -O ReleaseSmall -target aarch64-macos-none -femit-bin=timeout-darwin-apple-aarch64
zig build-exe ./timeout.zig -O ReleaseSmall -target x86_64-macos-none -femit-bin=timeout-darwin-apple-x86_64

# works on musl too (no gnu/libc dependency)
zig build-exe ./timeout.zig -O ReleaseSmall -target x86_64-linux-gnu -femit-bin=timeout-linux-unknown-x86_64
zig build-exe ./timeout.zig -O ReleaseSmall -target aarch64-linux-gnu -femit-bin=timeout-linux-unknown-aarch64
zig build-exe ./timeout.zig -O ReleaseSmall -target arm-linux-gnueabihf -femit-bin=timeout-linux-unknown-armv7l
zig build-exe ./timeout.zig -O ReleaseSmall -target arm-linux-gnueabi -femit-bin=timeout-linux-unknown-armv6l

# not supported yet (will require windows allocator and win signal mapping)
#zig build-exe ./timeout.zig -O ReleaseSmall -target x86_64-windows-gnu -femit-bin=timeout-windows-pc-x86_64
#zig build-exe ./timeout.zig -O ReleaseSmall -target aarch64-windows-gnu -femit-bin=timeout-windows-pc-aarch64
```

### Windows behavior

The Windows build uses Job Objects for process groups and console control
events for graceful timeout signals. `-f` targets only the child process.

- Named signals are accepted and mapped to Windows actions; `KILL` terminates
  the process or Job Object.
- Numeric signals are not supported and return 125.
- `INT` and other graceful signals use `CTRL_BREAK_EVENT` when a console is
  available; otherwise timeout falls back to termination.
- A timeout returns 124. Explicit `KILL` or kill-after returns 137.
- Windows has no POSIX signal-death status, so `-p` forwards the raw Windows
  child exit code.
- If `timeout.exe` is killed externally, descendants may outlive it because
  automatic Job Object cleanup is not available on all supported Windows 11
  builds.
