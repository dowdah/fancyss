// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	anytls "github.com/anytls/sing-anytls"
	"github.com/sagernet/sing/common/logger"
)

const version = "fss-anytls-client 0.1.4 (sing-anytls v0.0.11 + local fixes)"

type config struct {
	Listen, Server, PasswordFile, SNI, CAFile string
	Verify, RouterEgress                      bool
}

func parseConfig(args []string) (config, bool, error) {
	var c config
	var verify, insecure, showVersion bool
	f := flag.NewFlagSet("fss-anytls-client", flag.ContinueOnError)
	f.SetOutput(io.Discard) // Never echo command-line values in diagnostics.
	f.StringVar(&c.Listen, "l", "127.0.0.1:18081", "loopback SOCKS listen address")
	f.StringVar(&c.Server, "server", "", "AnyTLS host:port")
	f.StringVar(&c.PasswordFile, "password-file", "", "private password file")
	f.StringVar(&c.SNI, "sni", "", "TLS server name")
	f.StringVar(&c.CAFile, "ca-file", "", "optional CA PEM file")
	f.BoolVar(&verify, "verify", false, "verify upstream TLS")
	f.BoolVar(&insecure, "insecure", false, "use node's certificate exception")
	f.BoolVar(&c.RouterEgress, "router-egress", false, "mark upstream TCP sockets for the router firewall")
	f.BoolVar(&showVersion, "version", false, "show version")
	if len(args) == 1 && args[0] == "version" {
		return c, true, nil
	}
	if err := f.Parse(args); err != nil || f.NArg() != 0 {
		return c, false, errors.New("invalid arguments")
	}
	if showVersion {
		return c, true, nil
	}
	if verify && insecure {
		return c, false, errors.New("conflicting TLS flags")
	}
	c.Verify = !insecure
	return c, false, validateConfig(c)
}

func validateConfig(c config) error {
	host, port, err := net.SplitHostPort(c.Listen)
	if err != nil || !validPort(port) || !net.ParseIP(host).IsLoopback() {
		return errors.New("listen address must be loopback")
	}
	serverHost, serverPort, serverErr := net.SplitHostPort(c.Server)
	if serverErr != nil || serverHost == "" || !validPort(serverPort) || c.PasswordFile == "" || strings.ContainsAny(c.SNI, "\r\n\x00 ") {
		return errors.New("invalid node configuration")
	}
	return nil
}

func validPort(port string) bool {
	n, err := strconv.Atoi(port)
	return err == nil && n > 0 && n <= 65535
}

func readPassword(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", errors.New("password file unavailable")
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 || st.Size() < 1 || st.Size() > 65536 {
		return "", errors.New("password file must be private and nonempty")
	}
	b, err := io.ReadAll(io.LimitReader(f, 65537))
	if err != nil || len(b) == 0 || len(b) > 65536 {
		return "", errors.New("invalid password file")
	}
	return string(b), nil
}

func tlsConfig(c config) (*tls.Config, error) {
	host, _, _ := net.SplitHostPort(c.Server)
	name := c.SNI
	if name == "" {
		name = host
	}
	t := &tls.Config{ServerName: name, InsecureSkipVerify: !c.Verify, MinVersion: tls.VersionTLS12}
	if c.Verify {
		roots, err := x509.SystemCertPool()
		if err != nil {
			roots = x509.NewCertPool()
		}
		if c.CAFile != "" {
			pem, err := os.ReadFile(c.CAFile)
			if err != nil || !roots.AppendCertsFromPEM(pem) {
				return nil, errors.New("CA file unavailable")
			}
		}
		t.RootCAs = roots
	}
	return t, nil
}

func newDialer(routerEgress bool) (*net.Dialer, error) {
	dialer := &net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}
	if routerEgress {
		control, err := routerDialControl()
		if err != nil {
			return nil, err
		}
		dialer.Control = control
	}
	return dialer, nil
}

func newAnyTLSClient(ctx context.Context, c config, dialer *net.Dialer) (*anytls.Client, error) {
	password, err := readPassword(c.PasswordFile)
	if err != nil {
		return nil, err
	}
	t, err := tlsConfig(c)
	if err != nil {
		return nil, err
	}
	client, err := anytls.NewClient(ctx, anytls.ClientConfig{
		Password: password, Logger: logger.NOP(),
		IdleSessionCheckInterval: 30 * time.Second, IdleSessionTimeout: 30 * time.Second, MinIdleSession: 2,
		DialOut: func(ctx context.Context) (net.Conn, error) {
			ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			defer cancel()
			raw, err := dialer.DialContext(ctx, "tcp", c.Server)
			if err != nil {
				return nil, err
			}
			conn := tls.Client(raw, t)
			if err = conn.HandshakeContext(ctx); err != nil {
				raw.Close()
				return nil, err
			}
			return conn, nil
		},
	})
	if err != nil {
		return nil, errors.New("AnyTLS initialization failed")
	}
	return client, nil
}

func run(ctx context.Context, c config) error {
	dialer, err := newDialer(c.RouterEgress)
	if err != nil {
		return err
	}
	client, err := newAnyTLSClient(ctx, c, dialer)
	if err != nil {
		return err
	}
	defer client.Close()
	ln, err := net.Listen("tcp", c.Listen)
	if err != nil {
		return errors.New("SOCKS listen failed")
	}
	s := newServer(client)
	return s.serve(ctx, ln)
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if err := runCommand(ctx, os.Args[1:]); err != nil {
		// Initialization errors contain no node credentials or request destinations.
		fmt.Fprintln(os.Stderr, "fss-anytls-client:", err)
		os.Exit(1)
	}
}

func runCommand(ctx context.Context, args []string) error {
	if len(args) == 1 && args[0] == "--capabilities" {
		fmt.Println("webtest-manifest")
		return nil
	}
	if len(args) == 1 && args[0] == "--check-router-egress" {
		_, err := routerDialControl()
		return err
	}
	if len(args) == 2 && args[0] == "--webtest-manifest" {
		manifest, err := readWebtestManifest(args[1])
		if err != nil {
			return err
		}
		return runWebtest(ctx, manifest)
	}
	c, showVersion, err := parseConfig(args)
	if showVersion {
		fmt.Println(version)
		return nil
	}
	if err != nil {
		return err
	}
	return run(ctx, c)
}
