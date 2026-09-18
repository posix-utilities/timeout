//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// Windows has no POSIX signals. Named signals are accepted for CLI
// portability and mapped to the closest Windows action:
//
//   - KILL         → terminate (job object or process)
//   - INT          → GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT)
//     (CTRL_C is disabled in new process groups; see below)
//   - everything   → GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT)
//     else
//
// The child is created in a new process group (CREATE_NEW_PROCESS_GROUP)
// so ctrl events sent to it don't also hit timeout.exe itself. CTRL_C is
// disabled in new process groups, so all graceful signals use CTRL_BREAK.
// Console control events only reach processes attached to a console;
// when the event cannot be delivered, terminate is used instead.
// Numeric signals are rejected.

const (
	actTerminate = iota
	actCtrlC     // unused (CTRL_C disabled in new process groups) but kept for clarity
	actCtrlBreak
)

// Pseudo signal values, kept outside the real POSIX range so that
// signalName() (reverse map lookup) stays deterministic: every name
// has a unique value.
const windowsSigBase syscall.Signal = 0x100

var windowsActions = map[syscall.Signal]int{}

var windowsSigKill syscall.Signal

var windowsSignals = []struct {
	name string
	act  int
}{
	{"KILL", actTerminate},
	{"INT", actCtrlBreak},
	{"ABRT", actCtrlBreak},
	{"ALRM", actCtrlBreak},
	{"BUS", actCtrlBreak},
	{"CHLD", actCtrlBreak},
	{"CONT", actCtrlBreak},
	{"FPE", actCtrlBreak},
	{"HUP", actCtrlBreak},
	{"ILL", actCtrlBreak},
	{"IO", actCtrlBreak},
	{"IOT", actCtrlBreak},
	{"PIPE", actCtrlBreak},
	{"PROF", actCtrlBreak},
	{"QUIT", actCtrlBreak},
	{"SEGV", actCtrlBreak},
	{"STOP", actCtrlBreak},
	{"SYS", actCtrlBreak},
	{"TERM", actCtrlBreak},
	{"TRAP", actCtrlBreak},
	{"TSTP", actCtrlBreak},
	{"TTIN", actCtrlBreak},
	{"TTOU", actCtrlBreak},
	{"URG", actCtrlBreak},
	{"USR1", actCtrlBreak},
	{"USR2", actCtrlBreak},
	{"VTALRM", actCtrlBreak},
	{"WINCH", actCtrlBreak},
	{"XCPU", actCtrlBreak},
	{"XFSZ", actCtrlBreak},
}

func init() {
	for i, s := range windowsSignals {
		sig := windowsSigBase + syscall.Signal(i)
		signalMap[s.name] = sig
		windowsActions[sig] = s.act
	}
	windowsSigKill = signalMap["KILL"]
	fnNumericSignal = func(num int) (syscall.Signal, error) {
		return 0, fmt.Errorf("numeric signals not supported on windows")
	}
}

var (
	kernel32               = syscall.NewLazyDLL("kernel32.dll")
	procCreateJobObjectW   = kernel32.NewProc("CreateJobObjectW")
	procAssignJobObject    = kernel32.NewProc("AssignProcessToJobObject")
	procTerminateJobObject = kernel32.NewProc("TerminateJobObject")
	procTerminateProcess   = kernel32.NewProc("TerminateProcess")
	procOpenProcess        = kernel32.NewProc("OpenProcess")
	procGenerateCtrlEvent  = kernel32.NewProc("GenerateConsoleCtrlEvent")
)

const (
	createNewProcessGroup = 0x00000200
	procAllAccess         = 0x001F0000
	ctrlCEVENT            = 0
	ctrlBreakEVENT        = 1
)

// exit code assigned to terminated children so that -p (preserve
// status) reports 137, matching unix SIGKILL semantics (128+9).
const winKillExitCode = 137

// Single-child tool: job/child handle state lives at package level.
var (
	jobHandle   syscall.Handle
	jobJoined   bool
	childHandle syscall.Handle
)

func createJobObject() (syscall.Handle, error) {
	h, _, errno := procCreateJobObjectW.Call(0, 0)
	if h == 0 {
		return 0, errno
	}
	// SetInformationJobObject(KILL_ON_JOB_CLOSE) fails with
	// ERROR_INVALID_PARAMETER on some Windows 11 builds. Skipped —
	// TerminateJobObject handles group kill on timeout; the only loss
	// is auto-cleanup if timeout.exe itself is killed (edge case).
	return syscall.Handle(h), nil
}

// terminate kills the child and (when group mode is active) its
// descendants. asKill reports whether this was an explicit KILL
// (user's -s KILL or kill-after) for the 137 exit-code rule — a
// graceful timeout that fell back to terminate still reports 124.
func (t *Timeout) terminate(asKill bool) {
	if asKill {
		t.killed.Store(true)
	}
	if !t.ignoreProcessGroup && jobJoined {
		_, _, _ = procTerminateJobObject.Call(uintptr(jobHandle), winKillExitCode)
		return
	}
	if childHandle != 0 {
		_, _, _ = procTerminateProcess.Call(uintptr(childHandle), winKillExitCode)
	}
}

// cleanupJob kills any surviving descendants in the job (e.g. an
// orphaned grandchild after the primary child died from a ctrl event).
func (t *Timeout) cleanupJob() {
	if !t.ignoreProcessGroup && jobJoined {
		_, _, _ = procTerminateJobObject.Call(uintptr(jobHandle), 1)
	}
}

// sendTimeoutSignal delivers the parsed timeout signal.
// Console control events are best-effort: when delivery fails (no
// console attached), the child is terminated instead.
func (t *Timeout) sendTimeoutSignal() {
	t.verboseSignal(t.timeoutSignal)
	proc := t.cmd.Process
	if proc == nil {
		return
	}
	switch windowsActions[t.timeoutSignal] {
	case actTerminate:
		t.terminate(true)
	case actCtrlC:
		_, _, err := procGenerateCtrlEvent.Call(ctrlCEVENT, uintptr(proc.Pid))
		if err != nil {
			t.terminate(false)
		}
	default: // actCtrlBreak
		_, _, err := procGenerateCtrlEvent.Call(ctrlBreakEVENT, uintptr(proc.Pid))
		if err != nil {
			t.terminate(false)
		}
	}
}

func (t *Timeout) Start() error {
	ctxBg := context.Background()
	if t.timeoutDuration > 0 {
		t.ctx, t.cancel = context.WithTimeout(ctxBg, t.timeoutDuration)
	} else {
		t.ctx, t.cancel = context.WithCancel(ctxBg)
	}

	if !t.ignoreProcessGroup {
		var err error
		jobHandle, err = createJobObject()
		if err != nil {
			return err
		}
	}

	t.cmd = exec.CommandContext(t.ctx, t.command, t.arguments...)
	t.cmd.Cancel = func() error {
		t.sendTimeoutSignal()
		if t.preserveStatus {
			return fmt.Errorf("force Wait() to preserve error: %w", os.ErrProcessDone)
		}
		return fmt.Errorf("deadline reached")
	}
	t.cmd.Stdin = os.Stdin
	t.cmd.Stdout = os.Stdout
	t.cmd.Stderr = os.Stderr
	t.cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNewProcessGroup}

	if err := t.cmd.Start(); err != nil {
		return err
	}

	h, _, _ := procOpenProcess.Call(procAllAccess, 0, uintptr(t.cmd.Process.Pid))
	childHandle = syscall.Handle(h)

	// Join the child (and everything it spawns afterwards) to the job
	// object. Small race: descendants spawned between Start() and the
	// assignment escape the job — accepted, see plan.
	if !t.ignoreProcessGroup && childHandle != 0 {
		_, _, err := procAssignJobObject.Call(uintptr(jobHandle), uintptr(childHandle))
		jobJoined = err == nil
	}

	// Cleanup goroutine: after timeout fires, wait a grace period
	// (kill-after delay if -k specified, otherwise 500ms default)
	// then force-terminate if the child hasn't exited. Windows
	// processes often ignore console ctrl events, so this ensures
	// prompt kill. Exit code: 137 if -k was given, 124 otherwise.
	grace := t.killDelay
	asKill := t.killDelay >= 0
	if grace < 0 {
		grace = 500 * time.Millisecond
		asKill = false
	}
	go func() {
		<-t.ctx.Done()
		if t.ctx.Err() != context.DeadlineExceeded {
			return
		}
		time.Sleep(grace)
		if t.childExited.Load() {
			return // child exited from ctrl event
		}
		if asKill {
			t.verboseSignal(windowsSigKill)
		}
		t.terminate(asKill)
	}()

	return nil
}

func (t *Timeout) Wait() error {
	defer t.cancel()

	waitErr := t.cmd.Wait()
	t.childExited.Store(true)
	ctxErr := t.ctx.Err()
	timedOut := ctxErr == context.DeadlineExceeded

	// If timed out and not preserving status: 137 when we terminated
	// the child (parity with unix SIGKILL rule), 124 otherwise.
	if timedOut && !t.preserveStatus {
		if t.killed.Load() {
			os.Exit(winKillExitCode)
		}
		// Clean up surviving descendants (e.g. orphaned grandchild)
		t.cleanupJob()
		os.Exit(124)
	}

	// Forward the child's exit status (raw exit code; Windows has no
	// signal-death 128+N semantics).
	if waitErr != nil {
		if exitError, ok := waitErr.(*exec.ExitError); ok {
			os.Exit(exitError.ExitCode())
		}
	}

	return waitErr
}
