package main

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	anytls "github.com/anytls/sing-anytls"
	"github.com/anytls/sing-anytls/padding"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
)

func TestPaddingSchemeBounds(t *testing.T) {
	for _, scheme := range []string{
		"stop=65",
		"stop=2\n64=1-1",
		"stop=2\n1=" + strings.Repeat("c,", 32) + "1-1",
		"stop=2\n1=16385-16385",
		"stop=2\n1=1-1\n1=2-2",
		"stop=2\n0=c",
	} {
		if padding.NewPaddingFactory([]byte(scheme)) != nil {
			t.Fatalf("accepted out-of-bounds scheme %q", scheme)
		}
	}
	valid := padding.NewPaddingFactory([]byte("stop=64\n0=16384-16384\n1=500-400,c,9-9"))
	if valid == nil {
		t.Fatal("rejected bounded ranges and check marker")
	}
	sizes := valid.GenerateRecordPayloadSizes(1)
	if len(sizes) != 3 || sizes[0] < 400 || sizes[0] >= 500 || sizes[1] != padding.CheckMark || sizes[2] != 9 {
		t.Fatalf("unexpected padding sizes %v", sizes)
	}
}

func TestServerPaddingUpdateRejectsMalformed(t *testing.T) {
	for name, scheme := range map[string]string{
		"overflow":  "stop=8\n1=2147483648-2147483648",
		"negative":  "stop=8\n1=-20-20",
		"oversized": "stop=8\n" + strings.Repeat(" ", 8192),
		"budget":    "stop=8\n0=16384-16384\n1=16384-16384,16384-16384,16384-16384",
	} {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			peers := make(chan net.Conn, 2)
			auth := make(chan uint16, 2)
			client, err := anytls.NewClient(ctx, anytls.ClientConfig{
				Password: "fixture", Logger: logger.NOP(),
				DialOut: func(context.Context) (net.Conn, error) {
					local, peer := net.Pipe()
					peer.SetDeadline(time.Now().Add(3 * time.Second))
					t.Cleanup(func() { peer.Close() })
					peers <- peer
					go func() {
						header := make([]byte, 34)
						if _, err := io.ReadFull(peer, header); err != nil {
							return
						}
						auth <- binary.BigEndian.Uint16(header[32:])
						_, _ = io.Copy(io.Discard, peer)
					}()
					return local, nil
				},
			})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			destination := M.ParseSocksaddr("fixture.invalid:443")
			first, err := client.CreateProxy(ctx, destination)
			if err != nil {
				t.Fatal(err)
			}
			defer first.Close()
			peer := <-peers
			frame := func(command byte, stream uint32, data string) {
				message := make([]byte, 7, 7+len(data))
				message[0] = command
				binary.BigEndian.PutUint32(message[1:], stream)
				binary.BigEndian.PutUint16(message[5:], uint16(len(data)))
				if _, err := peer.Write(append(message, data...)); err != nil {
					t.Fatal(err)
				}
			}
			frame(6, 0, scheme) // cmdUpdatePaddingScheme
			read := make(chan error, 1)
			go func() {
				_, err := io.ReadFull(first, make([]byte, 2))
				read <- err
			}()
			frame(2, 1, "ok") // cmdPSH follows the update in wire order
			select {
			case err := <-read:
				if err != nil {
					t.Fatal(err)
				}
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			second, err := client.CreateProxy(ctx, destination)
			if err != nil {
				t.Fatal(err)
			}
			defer second.Close()
			for range 2 {
				select {
				case length := <-auth:
					if length != 30 {
						t.Fatalf("authentication used unexpected padding length %d", length)
					}
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
			}
		})
	}
}
