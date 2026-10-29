package main

import (
	"context"
	anytls "github.com/anytls/sing-anytls"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// Deterministic transport backpressure after TLS; never contacts a real node.
type blockedWriteConn struct {
	net.Conn
	block  atomic.Bool
	closed chan struct{}
}

func (c *blockedWriteConn) Write(p []byte) (int, error) {
	if c.block.Load() {
		<-c.closed
		return 0, net.ErrClosed
	}
	return len(p), nil
}
func (c *blockedWriteConn) Close() error {
	select {
	case <-c.closed:
	default:
		close(c.closed)
	}
	return c.Conn.Close()
}
func newCancellationClient(t *testing.T, blocked bool) (*anytls.Client, *blockedWriteConn) {
	t.Helper()
	a, b := net.Pipe()
	raw := &blockedWriteConn{Conn: a, closed: make(chan struct{})}
	raw.block.Store(blocked)
	client, e := anytls.NewClient(context.Background(), anytls.ClientConfig{Password: "synthetic-test", Logger: logger.NOP(), DialOut: func(context.Context) (net.Conn, error) { return raw, nil }})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { raw.Close(); b.Close(); client.Close() })
	return client, raw
}
func checkCancelledSetup(t *testing.T, client *anytls.Client) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		c, e := client.CreateProxy(ctx, M.ParseSocksaddr("synthetic.invalid:443"))
		if c != nil {
			c.Close()
		}
		done <- e
	}()
	select {
	case e := <-done:
		if e == nil {
			t.Fatal("blocked setup succeeded")
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("setup ignored deadline")
	}
}
func TestRealClientAuthWriteCancellation(t *testing.T) {
	client, _ := newCancellationClient(t, true)
	checkCancelledSetup(t, client)
}
func TestRealClientPooledWriteCancellation(t *testing.T) {
	client, raw := newCancellationClient(t, false)
	first, e := client.CreateProxy(context.Background(), M.ParseSocksaddr("synthetic.invalid:443"))
	if e != nil {
		t.Fatal(e)
	}
	if e = first.Close(); e != nil {
		t.Fatal(e)
	}
	raw.block.Store(true)
	checkCancelledSetup(t, client)
}
func TestRealClientBlockedSetupShutdown(t *testing.T) {
	client, _ := newCancellationClient(t, true)
	ln, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s := newServer(client)
	s.connectTimeout = 10 * time.Second
	done := make(chan error, 1)
	go func() { done <- s.serve(ctx, ln) }()
	c, e := net.Dial("tcp", ln.Addr().String())
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(time.Second))
	c.Write([]byte{5, 1, 0})
	if _, e = io.ReadFull(c, make([]byte, 2)); e != nil {
		t.Fatal(e)
	}
	c.Write([]byte{5, 1, 0, 1, 1, 1, 1, 1, 1, 187})
	time.Sleep(30 * time.Millisecond)
	cancel()
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(300 * time.Millisecond):
		t.Fatal("shutdown retained blocked setup")
	}
}
