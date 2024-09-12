# [`timeout`](https://github.com/posix-utilities/timeout)

POSIX.1-2024 timeout

```sh
timeout [options] <duration> <command> [arguments...]
```

```text
-f             send timeout signal to the proccess only, not the process group
               (when the group is sent the signal, 'timeout' briefly ignores it)
-k <duration>  kill the process with SIGKILL after duration (respects -f)
-p             preserve original exit status, regardless if timeout occured
-s <signal>    TERM by default, or the chosen signal

   <duration>  such as 10, 10s, 2.5m, 24h, or 1.5d
```

## Exit Status

```text
0              no error (or no error from <command> with -p)
<n>            the return status of <command> (with -p)
124            if killed by timeout (if -p is NOT specified)
125            all other errors (if -p is NOT specified)
126            command not executable
127            command not found
```

# Build

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

## Go

```sh
curl https://weib.sh/go | sh
source ~/.config/envman/PATH.env

go tool dist list
```

```sh
go build -o ./timeout ./timeout.go
mv ./timeout ~/bin/
```

```sh
GOOS=darwin GOARCH=amd64 GOAMD64=v2 go build -o ./timeout-darwin-apple-x86_64 ./timeout.go
GOOS=darwin GOARCH=arm64 go build -o ./timeout-darwin-apple-aarch64 ./timeout.go
GOOS=linux GOARCH=amd64 GOAMD64=v2 go build -o ./timeout-linux-uknown-x86_64 ./timeout.go
GOOS=linux GOARCH=arm64 go build -o ./timeout-linux-uknown-aarch64 ./timeout.go
GOOS=linux GOARCH=arm GOARM=v7 go build -o ./timeout-linux-uknown-armv7l ./timeout.go
GOOS=linux GOARCH=arm GOARM=v6 go build -o ./timeout-linux-uknown-armv6l ./timeout.go

# not supported yet (will require build tags and windows syscalls)
#GOOS=windows GOARCH=amd64 GOAMD64=v2 go build -o ./timeout-windows-pc-x86_64 ./timeout.go
#GOOS=windows GOARCH=arm64 go build -o ./timeout-windows-pc-aarch64 ./timeout.go
```
