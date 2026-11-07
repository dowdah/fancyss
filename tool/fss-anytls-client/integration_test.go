package main

import (
	"context"
	"crypto/tls"
	anytls "github.com/anytls/sing-anytls"
	"github.com/anytls/sing-anytls/padding"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

type echoHandler struct{}

func (echoHandler) NewConnectionEx(_ context.Context, c net.Conn, _, _ M.Socksaddr, close N.CloseHandlerFunc) {
	defer c.Close()
	_, e := io.Copy(c, c)
	if close != nil {
		close(e)
	}
}
func TestRealProtocolTLSAndSessionReuse(t *testing.T) {
	certHost := httptest.NewTLSServer(http.NotFoundHandler())
	cert := certHost.TLS.Certificates
	certHost.Close()
	ln, e := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: cert})
	if e != nil {
		t.Fatal(e)
	}
	defer ln.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	svc, e := anytls.NewService(anytls.ServiceConfig{Users: []anytls.User{{Name: "test", Password: "private-test"}}, PaddingScheme: padding.DefaultPaddingScheme, Handler: echoHandler{}, Logger: logger.NOP()})
	if e != nil {
		t.Fatal(e)
	}
	var sessions atomic.Int32
	go func() {
		for {
			c, e := ln.Accept()
			if e != nil {
				return
			}
			sessions.Add(1)
			go func() { defer c.Close(); _ = svc.NewConnection(ctx, c, M.Socksaddr{}, nil) }()
		}
	}()
	client, e := anytls.NewClient(ctx, anytls.ClientConfig{Password: "private-test", Logger: logger.NOP(), IdleSessionCheckInterval: 30 * time.Second, IdleSessionTimeout: 30 * time.Second, MinIdleSession: 2, DialOut: func(ctx context.Context) (net.Conn, error) {
		return (&tls.Dialer{Config: &tls.Config{InsecureSkipVerify: true}}).DialContext(ctx, "tcp", ln.Addr().String())
	}})
	if e != nil {
		t.Fatal(e)
	}
	defer client.Close()
	for i := 0; i < 5; i++ {
		c, e := client.CreateProxy(ctx, M.ParseSocksaddr("echo.invalid:443"))
		if e != nil {
			t.Fatal(e)
		}
		c.SetDeadline(time.Now().Add(time.Second))
		if _, e = c.Write([]byte("payload")); e != nil {
			t.Fatal(e)
		}
		b := make([]byte, 7)
		if _, e = io.ReadFull(c, b); e != nil || string(b) != "payload" {
			t.Fatalf("roundtrip %q %v", b, e)
		}
		c.Close()
		time.Sleep(10 * time.Millisecond)
	}
	if sessions.Load() != 1 {
		t.Fatalf("five sequential streams used %d TLS sessions", sessions.Load())
	}
	// Verify the node's certificate choice actually controls trust.
	verified, e := tlsConfig(config{Server: ln.Addr().String(), Verify: true})
	if e != nil {
		t.Fatal(e)
	}
	bad, err := (&tls.Dialer{Config: verified}).DialContext(ctx, "tcp", ln.Addr().String())
	if bad != nil {
		bad.Close()
	}
	if err == nil {
		t.Fatal("untrusted test certificate accepted")
	}
}
