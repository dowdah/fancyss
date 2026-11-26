// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	anytls "github.com/anytls/sing-anytls"
	M "github.com/sagernet/sing/common/metadata"
)

const webtestManifestLimit = 1 << 20

type webtestManifest struct {
	RouterEgress bool          `json:"router_egress"`
	StopFile     string        `json:"stop_file,omitempty"`
	ReadyFile    string        `json:"ready_file,omitempty"`
	Nodes        []webtestNode `json:"nodes"`
}

type webtestNode struct {
	Listen       string `json:"listen"`
	Server       string `json:"server"`
	PasswordFile string `json:"password_file"`
	SNI          string `json:"sni,omitempty"`
	CAFile       string `json:"ca_file,omitempty"`
	Insecure     bool   `json:"insecure,omitempty"`
	StopFile     string `json:"stop_file"`
	StatusFile   string `json:"status_file,omitempty"`
}

func (n webtestNode) config() config {
	return config{
		Listen: n.Listen, Server: n.Server, PasswordFile: n.PasswordFile,
		SNI: n.SNI, CAFile: n.CAFile, Verify: !n.Insecure,
	}
}

func readWebtestManifest(path string) (webtestManifest, error) {
	var manifest webtestManifest
	f, err := os.Open(path)
	if err != nil {
		return manifest, errors.New("webtest manifest unavailable")
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 || st.Size() > webtestManifestLimit {
		return manifest, errors.New("webtest manifest must be a private file")
	}
	input := &io.LimitedReader{R: f, N: webtestManifestLimit + 1}
	d := json.NewDecoder(input)
	d.DisallowUnknownFields()
	var extra json.RawMessage
	if d.Decode(&manifest) != nil || d.Decode(&extra) != io.EOF || input.N == 0 || len(manifest.Nodes) == 0 {
		return manifest, errors.New("invalid webtest manifest")
	}
	listeners := make(map[string]bool, len(manifest.Nodes))
	files := make(map[string]bool, len(manifest.Nodes)*2+2)
	for _, name := range []string{manifest.StopFile, manifest.ReadyFile} {
		if name == "" {
			continue
		}
		path := filepath.Clean(name)
		if !filepath.IsAbs(path) || files[path] {
			return manifest, errors.New("invalid webtest batch signal file")
		}
		files[path] = true
	}
	for _, node := range manifest.Nodes {
		stop := filepath.Clean(node.StopFile)
		if !filepath.IsAbs(stop) || files[stop] || listeners[node.Listen] {
			return manifest, errors.New("invalid or duplicate webtest listener or stop file")
		}
		listeners[node.Listen] = true
		files[stop] = true
		if node.StatusFile != "" {
			status := filepath.Clean(node.StatusFile)
			if !filepath.IsAbs(status) || filepath.Dir(status) != filepath.Dir(stop) || files[status] {
				return manifest, errors.New("invalid or duplicate webtest status file")
			}
			files[status] = true
		}
	}
	return manifest, nil
}

func webtestStopped(path string) (bool, error) {
	if path == "" {
		return false, nil
	}
	if _, err := os.Stat(path); err == nil {
		return true, nil
	} else if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return false, errors.New("webtest stop file unavailable")
}

// A TCP readiness check only opens a local socket. Create a session pool when
// the first real SOCKS CONNECT arrives, so queued nodes hold no upstream state.
type webtestProxy struct {
	ctx    context.Context
	config config
	dialer *net.Dialer
	status string

	mu     sync.Mutex
	client *anytls.Client
	closed bool
}

func (p *webtestProxy) getClient() (*anytls.Client, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed || p.ctx.Err() != nil {
		return nil, net.ErrClosed
	}
	if p.client == nil {
		client, err := newAnyTLSClient(p.ctx, p.config, p.dialer)
		if err != nil {
			return nil, err
		}
		p.client = client
	}
	return p.client, nil
}

func (p *webtestProxy) CreateProxy(ctx context.Context, dest M.Socksaddr) (net.Conn, error) {
	client, err := p.getClient()
	var conn net.Conn
	if err == nil {
		conn, err = client.CreateProxy(ctx, dest)
	}
	if p.status != "" {
		_ = os.WriteFile(p.status, []byte(webtestProxyHealth(err)), 0600)
	}
	return conn, err
}

func webtestProxyHealth(err error) string {
	if err == nil {
		return "ok"
	}
	var cert *tls.CertificateVerificationError
	var dns *net.DNSError
	var timeout net.Error
	switch {
	case errors.As(err, &cert):
		return "tls"
	case errors.As(err, &timeout) && timeout.Timeout(), errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.As(err, &dns):
		return "dns"
	default:
		return "connection"
	}
}

func (p *webtestProxy) Close() error {
	p.mu.Lock()
	p.closed = true
	client := p.client
	p.client = nil
	p.mu.Unlock()
	if client != nil {
		return client.Close()
	}
	return nil
}

func runWebtest(ctx context.Context, manifest webtestManifest) error {
	if stopped, err := webtestStopped(manifest.StopFile); stopped || err != nil {
		return err
	}
	dialer, err := newDialer(manifest.RouterEgress)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	type endpoint struct {
		listener net.Listener
		stopFile string
		proxy    *webtestProxy
		cancel   context.CancelFunc
	}
	endpoints := make([]endpoint, 0, len(manifest.Nodes))
	var workers sync.WaitGroup
	defer func() {
		cancel()
		for _, endpoint := range endpoints {
			endpoint.listener.Close()
		}
		workers.Wait()
	}()

	for _, node := range manifest.Nodes {
		if err := validateConfig(node.config()); err != nil {
			if node.StatusFile != "" && os.WriteFile(node.StatusFile, []byte("configuration"), 0600) != nil {
				return errors.New("webtest status file unavailable")
			}
			continue
		}
		ln, err := net.Listen("tcp", node.Listen)
		if err != nil {
			if node.StatusFile != "" && os.WriteFile(node.StatusFile, []byte("connection"), 0600) != nil {
				return errors.New("webtest status file unavailable")
			}
			continue
		}
		nodeCtx, stop := context.WithCancel(ctx)
		proxy := &webtestProxy{ctx: nodeCtx, config: node.config(), dialer: dialer, status: node.StatusFile}
		endpoints = append(endpoints, endpoint{listener: ln, stopFile: node.StopFile, proxy: proxy, cancel: stop})
	}
	if manifest.ReadyFile != "" {
		if err := os.WriteFile(manifest.ReadyFile, nil, 0600); err != nil {
			return errors.New("webtest ready file unavailable")
		}
	}
	if len(endpoints) == 0 {
		return errors.New("no webtest listeners available")
	}
	results := make(chan error, len(endpoints))
	for _, endpoint := range endpoints {
		socks := newServer(endpoint.proxy)
		workers.Add(1)
		go func() {
			defer workers.Done()
			results <- socks.serve(endpoint.proxy.ctx, endpoint.listener)
		}()
	}
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for remaining := len(endpoints); remaining > 0; {
		select {
		case <-ctx.Done():
			return nil
		case err := <-results:
			if err != nil {
				return err
			}
			remaining--
		case <-tick.C:
			if stopped, err := webtestStopped(manifest.StopFile); stopped || err != nil {
				return err
			}
			for i := range endpoints {
				endpoint := &endpoints[i]
				stopped, err := webtestStopped(endpoint.stopFile)
				if err != nil {
					return err
				}
				if stopped {
					endpoint.cancel()
					endpoint.stopFile = ""
				}
			}
		}
	}
	return nil
}
