package main

import (
	"errors"
	"net"
	"os"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestRouterEgressWithOutputCapture(t *testing.T) {
	if os.Getenv("FSS_TEST_EGRESS_CAPTURE") != "1" {
		t.Skip("requires a private namespace with IPv4 and IPv6 OUTPUT redirect fixtures")
	}
	control, err := routerDialControl()
	if err != nil {
		t.Fatal(err)
	}
	for _, address := range []string{"127.0.0.2:29443", "[::1]:29444"} {
		t.Run(address, func(t *testing.T) {
			listener, err := net.Listen("tcp", address)
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			unmarked, err := net.DialTimeout("tcp", address, time.Second)
			if unmarked != nil {
				unmarked.Close()
			}
			if !errors.Is(err, unix.ECONNREFUSED) {
				t.Fatalf("unmarked dial did not hit the redirect: %v", err)
			}
			dialer := net.Dialer{Timeout: time.Second, Control: control}
			marked, err := dialer.Dial("tcp", address)
			if err != nil {
				t.Fatal(err)
			}
			defer marked.Close()
			receiver, err := listener.Accept()
			if err != nil {
				t.Fatal(err)
			}
			receiver.Close()
		})
	}
}
