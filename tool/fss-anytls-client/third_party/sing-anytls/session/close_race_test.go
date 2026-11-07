package session

import (
	"context"
	"io"
	"net"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/anytls/sing-anytls/padding"
	A "github.com/sagernet/sing/common/atomic"
	"github.com/sagernet/sing/common/logger"
)

type discardConn struct {
	done chan struct{}
	once sync.Once
}

func (c *discardConn) Read([]byte) (int, error)         { <-c.done; return 0, io.EOF }
func (c *discardConn) Write(b []byte) (int, error)      { return len(b), nil }
func (c *discardConn) Close() error                     { c.once.Do(func() { close(c.done) }); return nil }
func (c *discardConn) LocalAddr() net.Addr              { return &net.TCPAddr{} }
func (c *discardConn) RemoteAddr() net.Addr             { return &net.TCPAddr{} }
func (c *discardConn) SetDeadline(time.Time) error      { return nil }
func (c *discardConn) SetReadDeadline(time.Time) error  { return nil }
func (c *discardConn) SetWriteDeadline(time.Time) error { return nil }

func TestPublishedStreamCloseRace(t *testing.T) {
	runtime.GOMAXPROCS(4)
	var scheme A.TypedValue[*padding.PaddingFactory]
	padding.UpdatePaddingScheme(padding.DefaultPaddingScheme, &scheme)
	client := NewClient(context.Background(), logger.NOP(), func(context.Context, *padding.PaddingFactory) (net.Conn, error) {
		return &discardConn{done: make(chan struct{})}, nil
	}, &scheme, time.Minute, time.Minute, 2)
	defer client.Close()
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case <-stop:
				return
			default:
			}
			var stream *Stream
			client.sessionsLock.Lock()
			for _, session := range client.sessions {
				session.streamLock.Lock()
				for id, candidate := range session.streams {
					stream = candidate
					delete(session.streams, id)
					break
				}
				session.streamLock.Unlock()
				if stream != nil {
					break
				}
			}
			client.sessionsLock.Unlock()
			if stream != nil {
				// Same remove-then-close sequence as the protocol FIN receiver.
				stream.closeLocally()
			} else {
				runtime.Gosched()
			}
		}
	}()
	for i := 0; i < 2000; i++ {
		if _, err := client.CreateStream(context.Background()); err != nil {
			t.Fatal(err)
		}
		runtime.Gosched()
	}
	close(stop)
	<-done
}

func TestCloseCallbackRunsOnce(t *testing.T) {
	var scheme A.TypedValue[*padding.PaddingFactory]
	padding.UpdatePaddingScheme(padding.DefaultPaddingScheme, &scheme)
	session := newClientSession(&discardConn{done: make(chan struct{})}, scheme.Load(), &scheme, logger.NOP())
	var called A.Uint32
	stream, err := session.openStream(func() { called.Add(1) })
	if err != nil {
		t.Fatal(err)
	}
	var workers sync.WaitGroup
	for i := 0; i < 16; i++ {
		workers.Add(1)
		go func() { defer workers.Done(); stream.Close() }()
	}
	workers.Wait()
	if got := called.Load(); got != 1 {
		t.Fatalf("callback calls=%d", got)
	}
	session.Close()
}
