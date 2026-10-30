package main

import (
	"crypto/tls"
	"errors"
	"net"
	"testing"
	"time"
)

// Inspect the real ClientHello, including Go's suppression of IP literal SNI.
func TestTLSClientHelloServerName(t *testing.T) {
	for _, tc := range []struct {
		name, server, sni, want string
		verify                  bool
	}{
		{"verified default", "node.example:443", "", "node.example", true},
		{"insecure default", "node.example:443", "", "node.example", false},
		{"verified explicit", "node.example:443", "front.example", "front.example", true},
		{"insecure explicit", "node.example:443", "front.example", "front.example", false},
		{"ipv4", "192.0.2.1:443", "", "", false},
		{"ipv6", "[2001:db8::1]:443", "", "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg, err := tlsConfig(config{Server: tc.server, SNI: tc.sni, Verify: tc.verify})
			if err != nil {
				t.Fatal(err)
			}
			if cfg.InsecureSkipVerify == tc.verify {
				t.Fatal("certificate verification choice changed")
			}
			a, b := net.Pipe()
			defer a.Close()
			defer b.Close()
			a.SetDeadline(time.Now().Add(2 * time.Second))
			b.SetDeadline(time.Now().Add(2 * time.Second))
			seen := make(chan string, 1)
			done := make(chan struct{})
			go func() {
				defer close(done)
				_ = tls.Server(b, &tls.Config{GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
					seen <- hello.ServerName
					return nil, errors.New("ClientHello captured")
				}}).Handshake()
			}()
			_ = tls.Client(a, cfg).Handshake()
			<-done
			select {
			case got := <-seen:
				if got != tc.want {
					t.Fatalf("SNI = %q, want %q", got, tc.want)
				}
			default:
				t.Fatal("ClientHello not observed")
			}
		})
	}
}
