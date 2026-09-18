package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
}

func main() {
	opts := parseArgs(os.Args[1:])

	if len(opts.Positionals) < 2 {
		fnUsageError()
	}

	t := &Timeout{
		ignoreProcessGroup: opts.Foreground,
		preserveStatus:      opts.PreserveStatus,
		verbose:            opts.Verbose,
		command:             opts.Positionals[1],
		arguments:           opts.Positionals[2:],
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
			fmt.Fprintf(os.Stderr, "%s: %q not found\n", progName, t.command)
			os.Exit(127)
		}

		fmt.Fprintf(os.Stderr, "%s: failed to run command %q: %s\n", progName, t.command, err)
		os.Exit(126)
	}

	if err := t.Wait(); err != nil {
		os.Exit(125)
	}
}

func (t *Timeout) Start() error {
	ctxBg := context.Background()
	if t.timeoutDuration > 0 {
		t.ctx, t.cancel = context.WithTimeout(ctxBg, t.timeoutDuration)
	} else {
		t.ctx, t.cancel = context.WithCancel(ctxBg)
	}

	t.cmd = exec.CommandContext(t.ctx, t.command, t.arguments...)
	t.cmd.Cancel = func() error {
		t.verboseSignal(t.timeoutSignal)
		if t.ignoreProcessGroup {
			_ = t.cmd.Process.Signal(t.timeoutSignal)
		} else {
			_ = syscall.Kill(-t.cmd.Process.Pid, t.timeoutSignal)
		}

		if t.preserveStatus {
			return fmt.Errorf("force Wait() to preserve error: %w", os.ErrProcessDone)
		}
		return fmt.Errorf("deadline reached")
	}
	t.cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: !t.ignoreProcessGroup}
	t.cmd.Stdin = os.Stdin
	t.cmd.Stdout = os.Stdout
	t.cmd.Stderr = os.Stderr

	if err := t.cmd.Start(); err != nil {
		return err
	}

	// Kill-after goroutine: after timeout fires, send SIGKILL to the
	// process group after killDelay.
	if t.killDelay >= 0 {
		go func() {
			<-t.ctx.Done()
			// Only send SIGKILL on actual timeout, not normal cancellation
			// (cancel is called by defer in Wait() after the child exits).
			if t.ctx.Err() != context.DeadlineExceeded {
				return
			}
			time.Sleep(t.killDelay)
			proc := t.cmd.Process
			if proc == nil {
				return
			}
			t.verboseSignal(syscall.SIGKILL)
			if t.ignoreProcessGroup {
				_ = proc.Kill()
			} else {
				_ = syscall.Kill(-proc.Pid, syscall.SIGKILL)
			}
		}()
	}

	return nil
}

func (t *Timeout) verboseSignal(sig syscall.Signal) {
	if t.verbose {
		fmt.Fprintf(os.Stderr, "%s: sending signal %s to command '%s'\n",
			progName, signalName(sig), filepath.Base(t.command))
	}
}

func (t *Timeout) Wait() error {
	defer t.cancel()

	waitErr := t.cmd.Wait()
	ctxErr := t.ctx.Err()
	timedOut := ctxErr == context.DeadlineExceeded

	// If timed out and not preserving status, exit 124.
	// Exception: if the command was killed by SIGKILL (via -s KILL or -k),
	// exit 137 (128+9) instead — the documented exit status for SIGKILL
	// takes priority over the 124 timeout rule.
	if timedOut && !t.preserveStatus {
		if exitError, ok := waitErr.(*exec.ExitError); ok {
			status := exitError.Sys().(syscall.WaitStatus)
			if status.Signaled() && status.Signal() == syscall.SIGKILL {
				os.Exit(128 + int(status.Signal()))
			}
		}
		os.Exit(124)
	}

	// Forward the child's exit status.
	if waitErr != nil {
		if exitError, ok := waitErr.(*exec.ExitError); ok {
			status := exitError.Sys().(syscall.WaitStatus)
			if status.Signaled() {
				os.Exit(128 + int(status.Signal()))
			}
			os.Exit(status.ExitStatus())
		}
	}

	return waitErr
}