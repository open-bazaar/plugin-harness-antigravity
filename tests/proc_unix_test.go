//go:build unix

package antigravity_test

import "syscall"

func terminatePID(pid int) {
	_ = syscall.Kill(pid, syscall.SIGTERM)
}

func killPID(pid int) {
	_ = syscall.Kill(pid, syscall.SIGKILL)
}
