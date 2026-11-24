// The Swift integration harness owns this loopback-only Gateway/LRPC fixture.
package main

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/light-speak/luxo/pkg/lux/api"
	"github.com/light-speak/luxo/pkg/lux/auth"
	"github.com/light-speak/luxo/pkg/lux/codec"
	luxerrors "github.com/light-speak/luxo/pkg/lux/errors"
	"github.com/light-speak/luxo/pkg/lux/luvia"
	"github.com/light-speak/luxo/pkg/lux/rpc"
	"github.com/light-speak/luxo/pkg/lux/schema"
)

const identityID, watchID = 7, 8

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() (err error) {
	cfg, err := renewalConfig()
	if err != nil {
		return err
	}
	var started atomic.Int64
	backend, err := renewalRouter()
	if err != nil {
		return err
	}
	bindBackend(backend, &started)
	if err := backend.Prepare(); err != nil {
		return err
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	rpcServer := rpc.NewServer(backend)
	served := make(chan error, 1)
	go func() { served <- rpcServer.Serve(listener) }()
	defer func() {
		rpcServer.Close()
		err = errors.Join(err, <-served)
	}()

	client := rpc.NewClient(listener.Addr().String())
	defer client.Close()
	gateway, err := renewalRouter()
	if err != nil {
		return err
	}
	bindGateway(gateway, client)
	if err := gateway.Prepare(); err != nil {
		return err
	}
	return serveFixture(renewalEndpoints(cfg, gateway, backend, &started), gateway, backend)
}

func renewalConfig() (*auth.Config, error) {
	// The HTTP and RPC verification paths use the same process-local signing key.
	values := map[string]string{
		"JWT_SECRET": rand.Text(), "JWT_EXPIRES": "3s",
		"JWT_REFRESH": "true", "JWT_REFRESH_EXPIRES": "1m",
	}
	for name, value := range values {
		if err := os.Setenv(name, value); err != nil {
			return nil, err
		}
	}
	return auth.LoadConfig()
}

func renewalRouter() (*api.Router, error) {
	router := luvia.New().Router
	for _, definition := range []*schema.API{
		{ID: identityID, Name: "identity", ReturnType: "Int"},
		{ID: watchID, Name: "watch", ReturnType: "Int", Stream: true},
	} {
		if err := router.Schema.RegisterAPI(definition); err != nil {
			return nil, err
		}
	}
	return router, router.Registry.RegisterSchemaAPIs(router.Schema)
}

func bindBackend(router *api.Router, started *atomic.Int64) {
	router.Handle("identity", func(ctx context.Context, req *api.Request) error {
		identity := luvia.Identity(ctx)
		if identity == nil {
			return luxerrors.Unauthorized
		}
		req.Buf.B = codec.AppendSvarint(req.Buf.B, identity.ID())
		return nil
	})
	router.HandleStreamPrepared("watch", func(ctx context.Context, _ *api.Request, _ any) (api.PreparedStreamHandler, error) {
		identity := luvia.Identity(ctx)
		if identity == nil {
			return nil, luxerrors.Unauthorized
		}
		id := identity.ID()
		return func(ctx context.Context, stream *api.Stream) error {
			started.Add(1)
			if err := stream.Send(codec.AppendSvarint(nil, id)); err != nil {
				return err
			}
			<-ctx.Done()
			return ctx.Err()
		}, nil
	})
}

func bindGateway(router *api.Router, client *rpc.Client) {
	router.Handle("identity", func(ctx context.Context, req *api.Request) error {
		data, err := client.CallWithMaskContext(ctx, luvia.BearerToken(ctx), identityID, nil, nil)
		if err == nil {
			req.Buf.B = append(req.Buf.B, data...)
		}
		return err
	})
	router.HandleStreamForwarded("watch", func(ctx context.Context, req *api.Request, _ any) (api.PreparedStreamSource, error) {
		sub, err := client.SubscribeContext(ctx, luvia.BearerToken(ctx), watchID, req.FieldMask, req.BinaryParams())
		if err != nil {
			return api.PreparedStreamSource{}, err
		}
		return api.PreparedStreamSource{Close: sub.Close, Run: func(ctx context.Context, stream *api.Stream) error {
			return relayStream(ctx, stream, sub, router)
		}}, nil
	})
}

func relayStream(ctx context.Context, stream *api.Stream, sub *rpc.Subscription, router *api.Router) error {
	for {
		select {
		case data, ok := <-sub.Messages():
			if !ok {
				return sub.Err()
			}
			if !stream.Binary() {
				var err error
				data, err = router.StreamPayloadJSON("watch", data)
				if err != nil {
					return err
				}
			}
			if err := stream.Send(data); err != nil {
				return err
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func renewalEndpoints(cfg *auth.Config, gateway, backend *api.Router, started *atomic.Int64) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/ws", luvia.AuthMiddleware(cfg, gateway))
	mux.HandleFunc("GET /token", func(w http.ResponseWriter, _ *http.Request) {
		claims := func(dst []byte) ([]byte, error) { return append(dst, `{"id":42}`...), nil }
		access, err := auth.Sign(cfg, claims)
		if err != nil {
			http.Error(w, "sign access token", http.StatusInternalServerError)
			return
		}
		refresh, err := auth.SignRefresh(cfg, claims)
		if err != nil {
			http.Error(w, "sign refresh token", http.StatusInternalServerError)
			return
		}
		w.Header().Set("X-Refresh-Token", refresh)
		fmt.Fprint(w, access)
	})
	mux.HandleFunc("GET /refresh", func(w http.ResponseWriter, r *http.Request) {
		identity, err := auth.VerifyRefresh(cfg, strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
		if err != nil {
			http.Error(w, "invalid fixture refresh", http.StatusUnauthorized)
			return
		}
		claims := func(dst []byte) ([]byte, error) { return append(dst, identity.Raw()...), nil }
		access, err := auth.SignWithExpiry(cfg, claims, 30*time.Second)
		if err != nil {
			http.Error(w, "sign renewed access", http.StatusInternalServerError)
			return
		}
		fmt.Fprint(w, access)
	})
	mux.HandleFunc("GET /stats", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"started":%d,"gateway":%d,"backend":%d}`, started.Load(),
			gateway.Streams.SubCount("watch"), backend.Streams.SubCount("watch"))
	})
	return mux
}

func serveFixture(handler http.Handler, gateway, backend *api.Router) error {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var active sync.WaitGroup
	srv := &http.Server{
		BaseContext: func(net.Listener) context.Context { return ctx },
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			active.Add(1)
			defer active.Done()
			handler.ServeHTTP(w, r)
		}),
		ReadHeaderTimeout: 5 * time.Second,
	}
	served := make(chan error, 1)
	go func() { served <- srv.Serve(listener) }()
	stopped := make(chan error, 1)
	go func() { _, err := io.Copy(io.Discard, os.Stdin); stopped <- err }()
	fmt.Println("http://" + listener.Addr().String())

	select {
	case err := <-served:
		return fmt.Errorf("renewal HTTP fixture stopped before stdin closed: %w", err)
	case err = <-stopped:
	}
	cancel()
	shutdown, stop := context.WithTimeout(context.Background(), 5*time.Second)
	defer stop()
	if shutdownErr := srv.Shutdown(shutdown); shutdownErr != nil {
		return errors.Join(err, shutdownErr)
	}
	if serveErr := <-served; !errors.Is(serveErr, http.ErrServerClosed) {
		return errors.Join(err, serveErr)
	}

	done := make(chan struct{})
	go func() { active.Wait(); close(done) }()
	select {
	case <-done:
	case <-shutdown.Done():
		return errors.Join(err, shutdown.Err())
	}
	if gateway.Streams.SubCount("watch") != 0 || backend.Streams.SubCount("watch") != 0 {
		return errors.Join(err, errors.New("renewal fixture retained stream subscriptions"))
	}
	return err
}
