package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"time"
)

type Timeout struct {
	timeoutDuration    time.Duration
	timeoutSignal      syscall.Signal
	killDelay          time.Duration
	ignoreProcessGroup bool
	preserveStatus     bool
	verbose            bool
	command            string
	arguments          []string
	cmd                *exec.Cmd
	ctx                context.Context
	cancel             func()
	// killed is set when a terminating (KILL-equivalent) action was sent
	// to the child. Used on Windows, which cannot observe signal deaths.
	killed      atomic.Bool
	childExited atomic.Bool
}

func main() {
	opts := parseArgs(os.Args[1:])

	if len(opts.Positionals) < 2 {
		fnUsageError()
	}

	t := &Timeout{
		ignoreProcessGroup: opts.Foreground,
		preserveStatus:     opts.PreserveStatus,
		verbose:            opts.Verbose,
		command:            opts.Positionals[1],
		arguments:          opts.Positionals[2:],
	}

	var err error
	timeoutDuration := opts.Positionals[0]

	if t.timeoutDuration, err = ParseTimeout(timeoutDuration); err != nil {
		fnError(err.Error())
	}
	if t.timeoutDuration < 0 {
		fnError(fmt.Sprintf("invalid time interval %q", timeoutDuration))
	}

	if t.killDelay, err = ParseTimeout(opts.KillAfter); err != nil {
		fnError(err.Error())
	}
	if t.killDelay < 0 && t.killDelay != -1*time.Second {
		fnError(fmt.Sprintf("invalid time interval %q", opts.KillAfter))
	}

	if t.timeoutSignal, err = ParseSignal(opts.Signal); err != nil {
		fnError(err.Error())
	}

	if err := t.Start(); err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			fmt.Fprintf(os.Stderr, "%s: %q not found\n", name, t.command)
			os.Exit(127)
		}

		fmt.Fprintf(os.Stderr, "%s: failed to run command %q: %s\n", name, t.command, err)
		os.Exit(126)
	}

	if err := t.Wait(); err != nil {
		os.Exit(125)
	}
}

func (t *Timeout) verboseSignal(sig syscall.Signal) {
	if t.verbose {
		fmt.Fprintf(os.Stderr, "%s: sending signal %s to command '%s'\n",
			name, signalName(sig), filepath.Base(t.command))
	}
}
