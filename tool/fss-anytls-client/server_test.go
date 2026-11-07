package main

import (
	"bufio"
	"context"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/protocol/socks"
	"github.com/sagernet/sing/protocol/socks/socks5"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

type fakeProxy struct {
	calls atomic.Int32
	stall bool
}

func (f *fakeProxy) CreateProxy(ctx context.Context, _ M.Socksaddr) (net.Conn, error) {
	f.calls.Add(1)
	if f.stall {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	a, b := net.Pipe()
	go func() {
		defer b.Close()
		buf := make([]byte, 4096)
		for {
			n, e := b.Read(buf)
			if n > 0 {
				if _, w := b.Write(buf[:n]); w != nil {
					return
				}
			}
			if e != nil {
				return
			}
		}
	}()
	return &addressedConn{a}, nil
}

type addressedConn struct{ net.Conn }

func (c *addressedConn) LocalAddr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1234}
}
func startTestServer(t *testing.T, f proxyClient, timeout time.Duration) (*server, string) {
	t.Helper()
	ln, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := newServer(f)
	s.handshakeTimeout = timeout
	s.connectTimeout = 80 * time.Millisecond
	done := make(chan error, 1)
	go func() { done <- s.serve(ctx, ln) }()
	t.Cleanup(func() {
		cancel()
		select {
		case e := <-done:
			if e != nil {
				t.Error(e)
			}
		case <-time.After(2 * time.Second):
			t.Error("shutdown did not release clients")
		}
	})
	return s, ln.Addr().String()
}
func dial(t *testing.T, addr string) net.Conn {
	t.Helper()
	c, e := net.DialTimeout("tcp", addr, time.Second)
	if e != nil {
		t.Fatal(e)
	}
	c.SetDeadline(time.Now().Add(2 * time.Second))
	return c
}
func greet(t *testing.T, c net.Conn) {
	t.Helper()
	c.Write([]byte{5, 1, 0})
	r := make([]byte, 2)
	if _, e := io.ReadFull(c, r); e != nil || r[0] != 5 || r[1] != 0 {
		t.Fatalf("greeting failed: %v %v", r, e)
	}
}
func TestConcurrentAdmissionBeyondOldLimit(t *testing.T) {
	f := &fakeProxy{}
	_, addr := startTestServer(t, f, 5*time.Second)
	held := make([]net.Conn, 0, 256)
	defer func() {
		for _, c := range held {
			c.Close()
		}
	}()
	for i := 0; i < 256; i++ {
		c := dial(t, addr)
		held = append(held, c)
		greet(t, c)
	}
	extra := dial(t, addr)
	defer extra.Close()
	extra.SetDeadline(time.Now().Add(300 * time.Millisecond))
	extra.Write([]byte{5, 1, 0})
	var b [2]byte
	_, e := extra.Read(b[:])
	if e == nil {
		t.Fatal("overload was accepted")
	}
	if n, ok := e.(net.Error); ok && n.Timeout() {
		t.Fatal("overload queued instead of closing")
	}
	if f.calls.Load() != 0 {
		t.Fatal("greetings must not create upstream sessions")
	}
}
func TestHandshakeTimeoutReleasesSlot(t *testing.T) {
	s, addr := startTestServer(t, &fakeProxy{}, 40*time.Millisecond)
	c := dial(t, addr)
	defer c.Close()
	greet(t, c)
	_, e := c.Read(make([]byte, 1))
	if e == nil {
		t.Fatal("incomplete handshake stayed open")
	}
	limit := time.Now().Add(time.Second)
	for len(s.slots) != 0 && time.Now().Before(limit) {
		time.Sleep(time.Millisecond)
	}
	if len(s.slots) != 0 {
		t.Fatal("timed out handshake retained slot")
	}
}
func TestConnectTimeoutAndUDPFailure(t *testing.T) {
	f := &fakeProxy{stall: true}
	_, addr := startTestServer(t, f, time.Second)
	c := dial(t, addr)
	defer c.Close()
	begin := time.Now()
	_, e := socks.ClientHandshake5(c, socks5.CommandConnect, M.ParseSocksaddr("example.invalid:443"), "", "")
	if e == nil || time.Since(begin) > time.Second {
		t.Fatal("outbound timeout not enforced")
	}
	udp := dial(t, addr)
	defer udp.Close()
	response, e := socks.ClientHandshake5(udp, socks5.CommandUDPAssociate, M.ParseSocksaddr("127.0.0.1:1234"), "", "")
	if e == nil || response.ReplyCode == socks5.ReplyCodeSuccess {
		t.Fatal("UDP silently accepted")
	}
	if f.calls.Load() != 1 {
		t.Fatal("UDP attempted an upstream connection")
	}
}
func TestPipelinedDataAndEstablishedConnectionSurviveHandshakeDeadline(t *testing.T) {
	_, addr := startTestServer(t, &fakeProxy{}, 70*time.Millisecond)
	c := dial(t, addr)
	defer c.Close()
	greet(t, c)
	host := "example.invalid"
	req := append([]byte{5, 1, 0, 3, byte(len(host))}, []byte(host)...)
	req = append(req, 1, 187)
	req = append(req, []byte("first")...)
	c.Write(req)
	r := bufio.NewReader(c)
	response, e := socks5.ReadResponse(r)
	if e != nil || response.ReplyCode != 0 {
		t.Fatalf("CONNECT failed: %v", e)
	}
	b := make([]byte, 5)
	if _, e = io.ReadFull(r, b); e != nil || string(b) != "first" {
		t.Fatalf("read-ahead lost: %q %v", b, e)
	}
	time.Sleep(100 * time.Millisecond)
	c.Write([]byte("later"))
	if _, e = io.ReadFull(r, b); e != nil || string(b) != "later" {
		t.Fatalf("established stream was timed out: %q %v", b, e)
	}
}
func TestConfigAndPasswordPrivacy(t *testing.T) {
	for _, args := range [][]string{{"--version"}, {"version"}} {
		_, v, e := parseConfig(args)
		if e != nil || !v {
			t.Fatal("version failed")
		}
	}
	base := []string{"-server", "example.invalid:443", "--password-file", "/test", "-l", "0.0.0.0:1234"}
	if _, _, e := parseConfig(base); e == nil {
		t.Fatal("public SOCKS listen accepted")
	}
	c, _, e := parseConfig([]string{"-server", "example.invalid:443", "--password-file", "/test", "--verify"})
	if e != nil || !c.Verify {
		t.Fatal("verification default broken")
	}
	c, _, e = parseConfig([]string{"-server", "example.invalid:443", "--password-file", "/test", "--insecure"})
	if e != nil || c.Verify {
		t.Fatal("node exception not preserved")
	}
	p := filepath.Join(t.TempDir(), "pass")
	os.WriteFile(p, []byte("synthetic\n"), 0644)
	if _, e := readPassword(p); e == nil {
		t.Fatal("public password accepted")
	}
	os.Chmod(p, 0600)
	pw, e := readPassword(p)
	if e != nil || pw != "synthetic\n" {
		t.Fatal("password bytes changed")
	}
}
