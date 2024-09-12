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
