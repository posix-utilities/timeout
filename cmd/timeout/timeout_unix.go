//go:build unix

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"
)

func init() {
	signalMap["ABRT"] = syscall.SIGABRT
	signalMap["ALRM"] = syscall.SIGALRM
	signalMap["BUS"] = syscall.SIGBUS
	signalMap["CHLD"] = syscall.SIGCHLD
	signalMap["CONT"] = syscall.SIGCONT
	signalMap["FPE"] = syscall.SIGFPE
	signalMap["HUP"] = syscall.SIGHUP
	signalMap["ILL"] = syscall.SIGILL
	signalMap["INT"] = syscall.SIGINT
	signalMap["IO"] = syscall.SIGIO
	signalMap["IOT"] = syscall.SIGIOT
	signalMap["KILL"] = syscall.SIGKILL
	signalMap["PIPE"] = syscall.SIGPIPE
	signalMap["PROF"] = syscall.SIGPROF
	signalMap["QUIT"] = syscall.SIGQUIT
	signalMap["SEGV"] = syscall.SIGSEGV
	signalMap["STOP"] = syscall.SIGSTOP
	signalMap["SYS"] = syscall.SIGSYS
	signalMap["TERM"] = syscall.SIGTERM
	signalMap["TRAP"] = syscall.SIGTRAP
	signalMap["TSTP"] = syscall.SIGTSTP
	signalMap["TTIN"] = syscall.SIGTTIN
	signalMap["TTOU"] = syscall.SIGTTOU
	signalMap["URG"] = syscall.SIGURG
	signalMap["USR1"] = syscall.SIGUSR1
	signalMap["USR2"] = syscall.SIGUSR2
	signalMap["VTALRM"] = syscall.SIGVTALRM
	signalMap["WINCH"] = syscall.SIGWINCH
	signalMap["XCPU"] = syscall.SIGXCPU
	signalMap["XFSZ"] = syscall.SIGXFSZ
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
