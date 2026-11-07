// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"syscall"
	"time"

	singbuf "github.com/sagernet/sing/common/bufio"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/protocol/socks"
)

type proxyClient interface {
	CreateProxy(context.Context, M.Socksaddr) (net.Conn, error)
}

type server struct {
	client                           proxyClient
	slots                            chan struct{}
	handshakeTimeout, connectTimeout time.Duration
	mu                               sync.Mutex
	active                           map[net.Conn]struct{}
	wg                               sync.WaitGroup
}

func newServer(client proxyClient) *server {
	return &server{client: client, slots: make(chan struct{}, 256), handshakeTimeout: 5 * time.Second,
		connectTimeout: 10 * time.Second, active: make(map[net.Conn]struct{})}
}

func (s *server) serve(ctx context.Context, ln net.Listener) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			ln.Close()
		case <-done:
		}
	}()
	defer close(done)
	defer func() {
		cancel()
		ln.Close()
		// Close upstream sessions before joining handlers: a handler may be waiting
		// for remote I/O, rather than reading its already closed local socket.
		if closer, ok := s.client.(io.Closer); ok {
			_ = closer.Close()
		}
		s.mu.Lock()
		for c := range s.active {
			c.Close()
		}
		s.mu.Unlock()
		s.wg.Wait()
	}()
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return errors.New("SOCKS accept failed")
		}
		select {
		case s.slots <- struct{}{}:
			s.mu.Lock()
			s.active[c] = struct{}{}
			s.mu.Unlock()
			s.wg.Add(1)
			go func() {
				defer s.wg.Done()
				defer func() { c.Close(); s.mu.Lock(); delete(s.active, c); s.mu.Unlock(); <-s.slots }()
				s.handle(ctx, c)
			}()
		default:
			// Admission control never queues behind another client's long connection.
			c.Close()
		}
	}
}

// Preserve data sent with the CONNECT request instead of losing bufio read-ahead.
type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.reader.Read(p) }

func (s *server) handle(ctx context.Context, raw net.Conn) {
	raw.SetDeadline(time.Now().Add(s.handshakeTimeout))
	r := bufio.NewReader(raw)
	conn := &bufferedConn{Conn: raw, reader: r}
	_ = socks.HandleConnectionEx(ctx, conn, r, nil, s, M.SocksaddrFromNet(raw.RemoteAddr()), nil)
}

func (s *server) NewConnectionEx(ctx context.Context, c net.Conn, source, dest M.Socksaddr, onClose N.CloseHandlerFunc) {
	c.SetDeadline(time.Time{})
	dialCtx, cancel := context.WithTimeout(ctx, s.connectTimeout)
	upstream, err := s.client.CreateProxy(dialCtx, dest)
	cancel()
	if err != nil {
		c.SetWriteDeadline(time.Now().Add(time.Second))
		_ = N.ReportHandshakeFailure(c, err)
		if onClose != nil {
			onClose(err)
		}
		return
	}
	defer upstream.Close()
	if err = N.ReportConnHandshakeSuccess(c, upstream); err == nil {
		err = singbuf.CopyConn(ctx, c, upstream)
	}
	if onClose != nil {
		onClose(err)
	}
}

func (s *server) NewPacketConnectionEx(_ context.Context, c N.PacketConn, _, _ M.Socksaddr, onClose N.CloseHandlerFunc) {
	_ = N.ReportHandshakeFailure(c, syscall.EOPNOTSUPP)
	c.Close()
	if onClose != nil {
		onClose(syscall.EOPNOTSUPP)
	}
}
