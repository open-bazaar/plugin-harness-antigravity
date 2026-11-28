//go:build !unix

package antigravity_test

import "os"

func terminatePID(pid int) {
	if p, err := os.FindProcess(pid); err == nil {
		_ = p.Kill()
	}
}

func killPID(pid int) {
	terminatePID(pid)
}
