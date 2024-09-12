package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Timeout struct {
	timeoutDuration    time.Duration
	timeoutSignal      syscall.Signal
	killDelay          time.Duration
	ignoreProcessGroup bool
	preserveStatus     bool
	command            string
	arguments          []string
	cmd                *exec.Cmd
	ctx                context.Context
	cancel             func()
}

func main() {
	var err error

	t := &Timeout{}

	var timeoutDuration string
	var timeoutSignal string
	var killDelay string

	flag.StringVar(&timeoutSignal, "s", "TERM", "Signal to send when time is up")
	flag.StringVar(&killDelay, "k", "-1", "Duration to wait before sending SIGKILL")
	flag.BoolVar(&t.ignoreProcessGroup, "f", false, "Send signal only to the child process")
	flag.BoolVar(&t.preserveStatus, "p", false, "Preserve exit status of the executed utility")

	flag.Parse()
	args := flag.Args()
	if len(args) < 2 {
		fmt.Fprintf(os.Stderr, "USAGE\n\ttimeout [-f] [-p] [-k duration] [-s signal] <duration> <command> [arguments...]\n")
		os.Exit(125)
	}
	timeoutDuration = args[0]

	t.command = args[1]
	t.arguments = args[2:]

	if t.timeoutDuration, err = ParseTimeout(timeoutDuration); err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(125)
		return
	}

	if t.killDelay, err = ParseTimeout(killDelay); err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(125)
		return
	}
	if t.killDelay < -1.0*time.Second {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(125)
		return
	}

	if t.timeoutSignal, err = ParseSignal(timeoutSignal); err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(125)
		return
	}

	if err := t.Start(); err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			fmt.Fprintf(os.Stderr, "%q not found", t.command)
			os.Exit(127)
		}

		fmt.Fprintf(os.Stderr, "cannot exec %q: %s", t.command, err)
		os.Exit(126)
		return
	}

	if err := t.Wait(); err != nil {
		// TODO
	}
}

func (t *Timeout) Start() error {
	ctxBg := context.Background()
	t.ctx, t.cancel = context.WithTimeout(ctxBg, t.timeoutDuration)

	t.cmd = exec.CommandContext(t.ctx, t.command, t.arguments...)
	t.cmd.Cancel = func() error {
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
	if t.killDelay > -1 {
		t.cmd.WaitDelay = t.killDelay
	}
	t.cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: !t.ignoreProcessGroup}
	t.cmd.Stdout = os.Stdout
	t.cmd.Stderr = os.Stderr

	return t.cmd.Start()
}

func (t *Timeout) Wait() error {
	defer t.cancel()

	waitErr := t.cmd.Wait()
	ctxErr := t.ctx.Err()
	if ctxErr == context.DeadlineExceeded {
		if t.killDelay > -1 {
			time.Sleep(t.killDelay)
			if t.ignoreProcessGroup {
				_ = t.cmd.Process.Kill()
			} else {
				_ = syscall.Kill(-t.cmd.Process.Pid, syscall.SIGKILL)
			}
		}

		if !t.preserveStatus {
			// if !p && !k => 124
			// if !p && k => unspecified: either 124 or original exit status
			os.Exit(124)
		}
	}
	if waitErr == exec.ErrWaitDelay {
		if !t.preserveStatus {
			os.Exit(124)
		}
	}

	if waitErr != nil {
		if exitError, ok := waitErr.(*exec.ExitError); ok {
			status := exitError.Sys().(syscall.WaitStatus)
			if status.Signaled() {
				syscall.Kill(os.Getpid(), status.Signal())
			} else {
				os.Exit(status.ExitStatus())
			}
		}
	}

	return waitErr
}

// ParseTimeout may remove a single suffix character of any of
// 's', 'm', 'h', 'd' will return a parsed float, or an error
func ParseTimeout(input string) (time.Duration, error) {
	// Define the characters that are allowed at the end
	allowedEndings := "smhd"

	isDay := false
	lastIndex := len(input) - 1
	fstr := input
	lastChar := ""

	if lastIndex >= 0 {
		lastChar = string(input[lastIndex])
		if lastChar == "d" {
		}
		if strings.Contains(allowedEndings, lastChar) {
			fstr = input[:lastIndex]
		}
	}
	if _, err := strconv.ParseFloat(fstr, 64); err != nil {
		return 0, fmt.Errorf("cannot parse duration %q", input)
	}
	if !strings.Contains(allowedEndings, lastChar) {
		input = input + "s"
	}

	duration, err := time.ParseDuration(input)
	if err != nil {
		return 0, fmt.Errorf("cannot parse duration %q", input)
	}
	if isDay {
		duration = duration * 24
	}

	return duration, nil
}

func ParseSignal(name string) (syscall.Signal, error) {
	if signal, ok := signalMap[strings.ToUpper(name)]; ok {
		return signal, nil
	}

	err := fmt.Errorf("unknown signal %q", name)
	return syscall.SIGTERM, err
}

var signalMap = map[string]syscall.Signal{
	"ABRT": syscall.SIGABRT,
	"ALRM": syscall.SIGALRM,
	"BUS":  syscall.SIGBUS,
	"CHLD": syscall.SIGCHLD,
	"CONT": syscall.SIGCONT,
	"HUP":  syscall.SIGHUP,
	"ILL":  syscall.SIGILL,
	"INT":  syscall.SIGINT,
	"KILL": syscall.SIGKILL,
	"PIPE": syscall.SIGPIPE,
	"QUIT": syscall.SIGQUIT,
	"SEGV": syscall.SIGSEGV,
	"STOP": syscall.SIGSTOP,
	"TERM": syscall.SIGTERM,
	"TRAP": syscall.SIGTRAP,
	"TSTP": syscall.SIGTSTP,
	"USR1": syscall.SIGUSR1,
	"USR2": syscall.SIGUSR2,
}
