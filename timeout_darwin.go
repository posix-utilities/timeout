//go:build darwin

package main

import "syscall"

func init() {
	signalMap["EMT"] = syscall.SIGEMT
	signalMap["INFO"] = syscall.SIGINFO
}
