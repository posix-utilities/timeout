//go:build linux

package main

import "syscall"

func init() {
	signalMap["CLD"] = syscall.SIGCLD
	signalMap["POLL"] = syscall.SIGPOLL
	signalMap["PWR"] = syscall.SIGPWR
	signalMap["STKFLT"] = syscall.SIGSTKFLT
}
