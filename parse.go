package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Options holds parsed command-line flags.
type Options struct {
	Signal         string
	KillAfter      string
	Foreground     bool
	PreserveStatus bool
	Verbose        bool
	Positionals    []string
}

const progName = "timeout"

func fnHelp() {
	fmt.Printf(`Usage: %s [OPTION]... DURATION COMMAND [ARG]...
Start COMMAND, and kill it if still running after DURATION.

Options requiring arguments are required in both short and long forms.
  -f, --foreground
         allow the command to read from the terminal and receive
         terminal signals; in this mode, child processes of the
         command are not timed out
  -h, --help
         show this help and exit
  -k, --kill-after=DURATION
         send SIGKILL if the command is still running this long
         after the initial signal
  -p, --preserve-status
         always return the command's exit status, even on timeout
  -s, --signal=SIGNAL
         signal name (e.g. HUP) or number to send on timeout
         (default: TERM); see 'kill -l' for available signals
  -v, --verbose
         report to stderr each signal sent on timeout
  -V, --version
         show version information and exit

DURATION is a floating point number with an optional suffix:
's' for seconds (the default), 'm' for minutes, 'h' for hours or 'd' for days.
A duration of 0 disables the associated timeout.

Upon timeout, send the TERM signal to COMMAND, if no other SIGNAL specified.
The TERM signal kills any process that does not block or catch that signal.
It may be necessary to use the KILL signal, since this signal can't be caught.

Exit status:
  124  if COMMAND times out, and --preserve-status is not specified
  125  if the timeout command itself fails
  126  if COMMAND is found but cannot be invoked
  127  if COMMAND cannot be found
  137  if COMMAND (or timeout itself) is sent the KILL (9) signal (128+9)
  -    the exit status of COMMAND otherwise
`, progName)
	os.Exit(0)
}

func fnVersion() {
	fmt.Printf("%s (posix-utilities) 1.0\n", progName)
	os.Exit(0)
}

func fnUsageError() {
	fmt.Fprintf(os.Stderr, "Try '%s --help' for more information.\n", progName)
	os.Exit(125)
}

func fnError(msg string) {
	fmt.Fprintf(os.Stderr, "%s: %s\n", progName, msg)
	fnUsageError()
}

// fnIsNegativeNumber returns true if s parses as a float, optionally
// followed by a single duration suffix (s, m, h, d).
// Used to distinguish negative durations (-1, -1.5, -2s) from flags (-f, -s).
func fnIsNegativeNumber(s string) bool {
	if len(s) < 2 || s[0] != '-' {
		return false
	}
	core := s
	switch s[len(s)-1] {
	case 's', 'm', 'h', 'd':
		core = s[:len(s)-1]
	}
	_, err := strconv.ParseFloat(core, 64)
	return err == nil
}

// parseArgs parses command-line arguments into Options.
// Supports short options (-f, -fp, -s TERM, -sTERM, -s=TERM),
// long options (--foreground, --signal=TERM, --signal TERM),
// -- to end option parsing, and negative numbers as positionals.
func parseArgs(args []string) *Options {
	opts := &Options{
		Signal:    "TERM",
		KillAfter: "-1",
	}

	i := 0
	flagDone := false
	for !flagDone && i < len(args) {
		arg := args[i]

		// -- ends option parsing
		if arg == "--" {
			i++
			flagDone = true
			break
		}

		// Long option
		if strings.HasPrefix(arg, "--") {
			i = parseLongOption(args, i, opts)
			continue
		}

		// Short option(s) — may be combined (-fp, -fsTERM)
		if len(arg) >= 2 && arg[0] == '-' && arg != "-" && !fnIsNegativeNumber(arg) {
			i = parseShortOptions(args, i, opts)
			continue
		}

		// Non-option argument (duration or command)
		flagDone = true
	}

	opts.Positionals = args[i:]
	return opts
}

// parseLongOption handles a single --long-option argument.
// Returns the next index to process.
func parseLongOption(args []string, i int, opts *Options) int {
	arg := args[i]

	// Split on = if present
	name := arg
	value := ""
	hasValue := false
	if idx := strings.Index(arg, "="); idx >= 0 {
		name = arg[:idx]
		value = arg[idx+1:]
		hasValue = true
	}

	switch name {
	case "--help":
		fnHelp()
	case "--version":
		fnVersion()
	case "--foreground":
		opts.Foreground = true
		return i + 1
	case "--preserve-status":
		opts.PreserveStatus = true
		return i + 1
	case "--verbose":
		opts.Verbose = true
		return i + 1
	case "--signal":
		return consumeValue(args, i, name, hasValue, value, func(v string) { opts.Signal = v })
	case "--kill-after":
		return consumeValue(args, i, name, hasValue, value, func(v string) { opts.KillAfter = v })
	default:
		fnError(fmt.Sprintf("unrecognized option '%s'", arg))
		return 0 // unreachable
	}
	return 0 // unreachable
}

// parseShortOptions handles -x, -xy, -xyVALUE, -x VALUE.
// Returns the next index to process.
func parseShortOptions(args []string, i int, opts *Options) int {
	arg := args[i]
	// Process each character after the '-'
	for j := 1; j < len(arg); j++ {
		c := arg[j]
		switch c {
		case 'h':
			fnHelp()
		case 'V':
			fnVersion()
		case 'f':
			opts.Foreground = true
		case 'p':
			opts.PreserveStatus = true
		case 'v':
			opts.Verbose = true
		case 's', 'k':
			// These take an argument: rest of string, or next arg
			rest := arg[j+1:]
			if len(rest) > 0 {
				// Strip leading = if present (-s=TERM form)
				if rest[0] == '=' {
					rest = rest[1:]
				}
				if c == 's' {
					opts.Signal = rest
				} else {
					opts.KillAfter = rest
				}
				return i + 1
			}
			// Consume next arg
			if i+1 >= len(args) {
				fnError(fmt.Sprintf("option requires an argument -- '%c'", c))
			}
			val := args[i+1]
			if c == 's' {
				opts.Signal = val
			} else {
				opts.KillAfter = val
			}
			return i + 2
		default:
			fnError(fmt.Sprintf("invalid option -- '%c'", c))
		}
	}
	return i + 1
}

// consumeValue handles a long option that may have its value
// via --opt=value or --opt value.
func consumeValue(args []string, i int, name string, hasValue bool, value string, setter func(string)) int {
	if hasValue {
		setter(value)
		return i + 1
	}
	if i+1 >= len(args) {
		fnError(fmt.Sprintf("option '%s' requires an argument", name))
	}
	setter(args[i+1])
	return i + 2
}

// signalName converts a syscall.Signal to its name (e.g. SIGTERM → "TERM").
// Falls back to the numeric value if the signal is not in the map.
func signalName(sig syscall.Signal) string {
	for name, s := range signalMap {
		if s == sig {
			return name
		}
	}
	return strconv.Itoa(int(sig))
}

// ParseTimeout parses a duration string like "10", "2.5m", "1.5d".
func ParseTimeout(input string) (time.Duration, error) {
	allowedEndings := "smhd"

	isDay := false
	lastIndex := len(input) - 1
	fstr := input
	lastChar := ""

	if lastIndex >= 0 {
		lastChar = string(input[lastIndex])
		if lastChar == "d" {
			isDay = true
		}
		if strings.Contains(allowedEndings, lastChar) {
			fstr = input[:lastIndex]
		}
	}
	if _, err := strconv.ParseFloat(fstr, 64); err != nil {
		return 0, fmt.Errorf("invalid time interval %q", input)
	}
	if !strings.Contains(allowedEndings, lastChar) {
		input = input + "s"
	} else if lastChar == "d" {
		input = input[:lastIndex] + "h"
	}

	duration, err := time.ParseDuration(input)
	if err != nil {
		return 0, fmt.Errorf("invalid time interval %q", input)
	}
	if isDay {
		duration = duration * 24
	}

	return duration, nil
}

// ParseSignal accepts numeric IDs ("9"), names ("KILL"), and
// SIG-prefixed names ("SIGKILL"). Case-insensitive.
func ParseSignal(name string) (syscall.Signal, error) {
	if num, err := strconv.Atoi(name); err == nil {
		if num <= 0 || num >= 128 {
			return 0, fmt.Errorf("invalid signal number %d", num)
		}
		return syscall.Signal(num), nil
	}

	upper := strings.ToUpper(name)
	if strings.HasPrefix(upper, "SIG") {
		upper = upper[3:]
	}

	if signal, ok := signalMap[upper]; ok {
		return signal, nil
	}

	return 0, fmt.Errorf("unknown signal %q", name)
}

var signalMap = map[string]syscall.Signal{
	"ABRT":   syscall.SIGABRT,
	"ALRM":   syscall.SIGALRM,
	"BUS":    syscall.SIGBUS,
	"CHLD":   syscall.SIGCHLD,
	"CONT":   syscall.SIGCONT,
	"FPE":    syscall.SIGFPE,
	"HUP":    syscall.SIGHUP,
	"ILL":    syscall.SIGILL,
	"INT":    syscall.SIGINT,
	"IO":     syscall.SIGIO,
	"IOT":    syscall.SIGIOT,
	"KILL":   syscall.SIGKILL,
	"PIPE":   syscall.SIGPIPE,
	"PROF":   syscall.SIGPROF,
	"QUIT":   syscall.SIGQUIT,
	"SEGV":   syscall.SIGSEGV,
	"STOP":   syscall.SIGSTOP,
	"SYS":    syscall.SIGSYS,
	"TERM":   syscall.SIGTERM,
	"TRAP":   syscall.SIGTRAP,
	"TSTP":   syscall.SIGTSTP,
	"TTIN":   syscall.SIGTTIN,
	"TTOU":   syscall.SIGTTOU,
	"URG":    syscall.SIGURG,
	"USR1":   syscall.SIGUSR1,
	"USR2":   syscall.SIGUSR2,
	"VTALRM": syscall.SIGVTALRM,
	"WINCH":  syscall.SIGWINCH,
	"XCPU":   syscall.SIGXCPU,
	"XFSZ":   syscall.SIGXFSZ,
}
