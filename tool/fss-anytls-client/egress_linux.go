// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"fmt"
	"syscall"

	"golang.org/x/sys/unix"
)

// This mark is reserved by the router's SHADOWSOCKS OUTPUT rules.
const routerEgressMark = 255

func setRouterEgressMark(fd int) error {
	if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_MARK, routerEgressMark); err != nil {
		return fmt.Errorf("set AnyTLS router egress mark: %w", err)
	}
	return nil
}

func routerDialControl() (func(string, string, syscall.RawConn) error, error) {
	// Detect missing privileges before announcing a ready SOCKS listener.
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("probe AnyTLS router egress mark: %w", err)
	}
	defer unix.Close(fd)
	if err := setRouterEgressMark(fd); err != nil {
		return nil, err
	}

	return func(_, _ string, raw syscall.RawConn) error {
		var markErr error
		if err := raw.Control(func(fd uintptr) { markErr = setRouterEgressMark(int(fd)) }); err != nil {
			return err
		}
		return markErr
	}, nil
}
