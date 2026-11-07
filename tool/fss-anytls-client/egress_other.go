//go:build !linux

// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"errors"
	"syscall"
)

func routerDialControl() (func(string, string, syscall.RawConn) error, error) {
	return nil, errors.New("AnyTLS router egress marking requires Linux")
}
