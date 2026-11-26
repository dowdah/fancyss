package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	anytls "github.com/anytls/sing-anytls"
	"github.com/anytls/sing-anytls/padding"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/protocol/socks"
	"github.com/sagernet/sing/protocol/socks/socks5"
)

func testWebtestUpstream(t *testing.T, ctx context.Context, cert []tls.Certificate, password string) (string, *atomic.Int32) {
	t.Helper()
	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: cert})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	service, err := anytls.NewService(anytls.ServiceConfig{
		Users:         []anytls.User{{Name: "webtest", Password: password}},
		PaddingScheme: padding.DefaultPaddingScheme, Handler: echoHandler{}, Logger: logger.NOP(),
	})
	if err != nil {
		t.Fatal(err)
	}
	count := new(atomic.Int32)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			count.Add(1)
			go func() { defer conn.Close(); _ = service.NewConnection(ctx, conn, M.Socksaddr{}, nil) }()
		}
	}()
	return listener.Addr().String(), count
}

func waitWebtestSocket(t *testing.T, address string, open bool) {
	t.Helper()
	for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); {
		conn, err := net.DialTimeout("tcp", address, 50*time.Millisecond)
		if conn != nil {
			conn.Close()
		}
		if (err == nil) == open {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("listener did not reach open=%v", open)
}

func testWebtestEcho(t *testing.T, address string) net.Conn {
	t.Helper()
	conn := dial(t, address)
	t.Cleanup(func() { conn.Close() })
	if _, err := socks.ClientHandshake5(conn, socks5.CommandConnect, M.ParseSocksaddr("echo.invalid:443"), "", ""); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 4)
	if _, err := conn.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(conn, reply); err != nil || string(reply) != "ping" {
		t.Fatalf("echo %q, error %v", reply, err)
	}
	return conn
}

func TestWebtestListenersRouteAndStopIndependently(t *testing.T) {
	certServer := httptest.NewTLSServer(http.NotFoundHandler())
	cert := certServer.TLS.Certificates
	certServer.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	root := t.TempDir()
	manifest := webtestManifest{StopFile: filepath.Join(root, "batch.stop")}
	var reservations []net.Listener
	var accepted []*atomic.Int32
	for _, label := range []string{"first", "second"} {
		upstream, count := testWebtestUpstream(t, ctx, cert, label)
		accepted = append(accepted, count)
		port, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		reservations = append(reservations, port)
		password := filepath.Join(root, label+".pass")
		if err := os.WriteFile(password, []byte(label), 0600); err != nil {
			t.Fatal(err)
		}
		manifest.Nodes = append(manifest.Nodes, webtestNode{
			Listen: port.Addr().String(), Server: upstream, PasswordFile: password,
			Insecure: true, StopFile: filepath.Join(root, label+".stop"),
		})
	}
	path := filepath.Join(root, "manifest.json")
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	for _, port := range reservations {
		port.Close()
	}
	done := make(chan error, 1)
	go func() { done <- runCommand(ctx, []string{"--webtest-manifest", path}) }()
	first, second := manifest.Nodes[0], manifest.Nodes[1]
	waitWebtestSocket(t, first.Listen, true)
	waitWebtestSocket(t, second.Listen, true)
	if accepted[0].Load() != 0 || accepted[1].Load() != 0 {
		t.Fatal("readiness probes opened upstream sessions")
	}
	firstConn := testWebtestEcho(t, first.Listen)
	if accepted[0].Load() != 1 || accepted[1].Load() != 0 {
		t.Fatal("first listener used the wrong upstream")
	}
	secondConn := testWebtestEcho(t, second.Listen)
	if accepted[1].Load() != 1 {
		t.Fatal("second listener did not use its own upstream")
	}

	if err := os.WriteFile(first.StopFile, nil, 0600); err != nil {
		t.Fatal(err)
	}
	waitWebtestSocket(t, first.Listen, false)
	assertWebtestClosed(t, firstConn)
	secondConn.Close()
	secondConn = testWebtestEcho(t, second.Listen)

	if err := os.WriteFile(manifest.StopFile, nil, 0600); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("batch did not shut down")
	}
	waitWebtestSocket(t, second.Listen, false)
	assertWebtestClosed(t, secondConn)
}

func assertWebtestClosed(t *testing.T, conn net.Conn) {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(time.Second))
	_, err := conn.Read(make([]byte, 1))
	if timeout, ok := err.(net.Error); err == nil || (ok && timeout.Timeout()) {
		t.Fatalf("connection remained open: %v", err)
	}
}
