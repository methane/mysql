package mysql

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"net"
	"testing"
	"time"
)

func TestConnectorReturnsTimeout(t *testing.T) {
	connector := newConnector(&Config{
		Net:     "tcp",
		Addr:    "1.1.1.1:1234",
		Timeout: 10 * time.Millisecond,
	})

	_, err := connector.Connect(context.Background())
	if err == nil {
		t.Fatal("error expected")
	}

	if nerr, ok := err.(*net.OpError); ok {
		expected := "dial tcp 1.1.1.1:1234: i/o timeout"
		if nerr.Error() != expected {
			t.Fatalf("expected %q, got %q", expected, nerr.Error())
		}
	} else {
		t.Fatalf("expected %T, got %T", nerr, err)
	}
}

func TestBeforeConnectUsesEffectiveTimeout(t *testing.T) {
	dialErr := errors.New("stop after observing dial context")
	var remaining time.Duration

	cfg := NewConfig()
	cfg.Timeout = 2 * time.Hour
	cfg.DialFunc = func(ctx context.Context, _, _ string) (net.Conn, error) {
		deadline, ok := ctx.Deadline()
		if !ok {
			t.Fatal("dial context has no deadline")
		}
		remaining = time.Until(deadline)
		return nil, dialErr
	}
	if err := cfg.Apply(BeforeConnect(func(_ context.Context, cfg *Config) error {
		cfg.Timeout = time.Hour
		return nil
	})); err != nil {
		t.Fatal(err)
	}

	connector, err := NewConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := connector.Connect(context.Background()); !errors.Is(err, dialErr) {
		t.Fatalf("Connect() error = %v, want %v", err, dialErr)
	}
	if remaining < 59*time.Minute || remaining > 61*time.Minute {
		t.Fatalf("dial timeout = %v, want about 1h", remaining)
	}
}

func TestBeforeConnectUpdatesDerivedTLSServerName(t *testing.T) {
	dialErr := errors.New("stop after observing effective config")
	tests := []struct {
		name       string
		serverName string
		want       string
	}{
		{"derived", "", "callback.example"},
		{"explicit", "database.example", "database.example"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var effectiveCfg *Config

			cfg := NewConfig()
			cfg.Addr = "initial.example:3306"
			cfg.TLS = &tls.Config{ServerName: tc.serverName}
			cfg.DialFunc = func(context.Context, string, string) (net.Conn, error) {
				return nil, dialErr
			}
			if err := cfg.Apply(BeforeConnect(func(_ context.Context, cfg *Config) error {
				cfg.Addr = "callback.example:3306"
				effectiveCfg = cfg
				return nil
			})); err != nil {
				t.Fatal(err)
			}

			connector, err := NewConnector(cfg)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := connector.Connect(context.Background()); !errors.Is(err, dialErr) {
				t.Fatalf("Connect() error = %v, want %v", err, dialErr)
			}
			if got := effectiveCfg.TLS.ServerName; got != tc.want {
				t.Errorf("TLS ServerName = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestBeforeConnectUsesEffectiveDialerAndAttributes(t *testing.T) {
	mock := &mockConn{
		data: []byte{72, 0, 0, 0, 10, 53, 46, 53, 46, 56, 0, 165, 0, 0, 0,
			60, 70, 63, 58, 68, 104, 34, 97, 0, 223, 247, 33, 2, 0, 31, 128, 21, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 98, 120, 114, 47, 85, 75, 109, 99, 51, 77,
			50, 64, 0, 109, 121, 115, 113, 108, 95, 110, 97, 116, 105, 118, 101, 95,
			112, 97, 115, 115, 119, 111, 114, 100},
		queuedReplies: [][]byte{
			{7, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0},
		},
	}

	var (
		initialDialCalled bool
		dialNetwork       string
		dialAddress       string
	)
	cfg := NewConfig()
	cfg.Addr = "initial.example:3306"
	cfg.ConnectionAttributes = "phase:initial"
	cfg.DialFunc = func(context.Context, string, string) (net.Conn, error) {
		initialDialCalled = true
		return nil, errors.New("initial dialer must not be called")
	}
	if err := cfg.Apply(BeforeConnect(func(_ context.Context, cfg *Config) error {
		cfg.Addr = "callback.example:3306"
		cfg.ConnectionAttributes = "phase:callback"
		cfg.DialFunc = func(_ context.Context, network, address string) (net.Conn, error) {
			dialNetwork = network
			dialAddress = address
			return mock, nil
		}
		return nil
	})); err != nil {
		t.Fatal(err)
	}

	connector, err := NewConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := connector.Connect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	if initialDialCalled {
		t.Fatal("Connect() used the pre-callback DialFunc")
	}
	if dialNetwork != "tcp" || dialAddress != "callback.example:3306" {
		t.Fatalf("dialed %s(%s), want tcp(callback.example:3306)", dialNetwork, dialAddress)
	}
	if !bytes.Contains(mock.written, []byte("phase\bcallback")) {
		t.Fatalf("handshake response does not contain callback attributes: %q", mock.written)
	}
	if bytes.Contains(mock.written, []byte("phase\x07initial")) {
		t.Fatalf("handshake response contains stale attributes: %q", mock.written)
	}
	if !bytes.Contains(mock.written, []byte("callback.example")) {
		t.Fatalf("handshake response does not contain callback server host: %q", mock.written)
	}
}
