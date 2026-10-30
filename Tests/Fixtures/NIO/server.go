package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"
)

func main() {
	if len(os.Args) != 3 {
		panic("certificate and key paths required")
	}
	var started, cancelled, http1Calls, overflowCancelled atomic.Int64
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if protocolAPI(w, r) {
			return
		}
		switch r.URL.Path {
		case "/identity":
			_, _ = io.WriteString(w, r.Proto+" "+r.RemoteAddr)
		case "/slow":
			started.Add(1)
			_, _ = w.Write([]byte{1})
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			cancelled.Add(1)
		case "/chunked-overflow":
			for range 3 {
				_, _ = w.Write(make([]byte, 512))
				w.(http.Flusher).Flush()
			}
			<-r.Context().Done()
			overflowCancelled.Add(1)
		case "/stats":
			_ = json.NewEncoder(w).Encode(map[string]int64{"started": started.Load(), "cancelled": cancelled.Load(), "http1": http1Calls.Load(), "overflowCancelled": overflowCancelled.Load()})
		case "/large":
			_, _ = w.Write(make([]byte, 4096))
		case "/truncated":
			w.Header().Set("Content-Length", "10")
			_, _ = w.Write([]byte{1})
		default:
			if r.ProtoMajor != 2 || r.Method != http.MethodPost || r.Header.Get("Content-Type") != "application/x-luxo" {
				http.Error(w, "wrong protocol", http.StatusBadRequest)
				return
			}
			_, _ = io.Copy(w, http.MaxBytesReader(w, r.Body, 2<<20))
		}
	})
	h2, h2Addr := start(handler, true)
	h1, h1Addr := start(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http1Calls.Add(1); protocolAPI(w, r) }), false)
	_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"h2": h2Addr, "h1": h1Addr})
	_, _ = io.Copy(io.Discard, os.Stdin)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = h2.Shutdown(ctx)
	_ = h1.Shutdown(ctx)
}

func start(handler http.Handler, http2 bool) (*http.Server, string) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	protocols.SetHTTP2(http2)
	server := &http.Server{Handler: handler, Protocols: protocols, ReadHeaderTimeout: 5 * time.Second, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12}}
	go func() {
		if err := server.ServeTLS(listener, os.Args[1], os.Args[2]); err != nil && err != http.ErrServerClosed {
			panic(err)
		}
	}()
	return server, "https://localhost:" + strconv.Itoa(listener.Addr().(*net.TCPAddr).Port)
}

// protocolAPI exercises the production transport, not the raw echo prototype.
func protocolAPI(w http.ResponseWriter, r *http.Request) bool {
	if r.URL.Path != "/api" && r.URL.Path != "/api-forbidden" && r.URL.Path != "/api-h1" {
		return false
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 2<<20))
	if err != nil || len(body) == 0 || (r.ProtoMajor != 2 && r.URL.Path != "/api-h1") || r.Method != http.MethodPost || r.Header.Get("Cache-Control") != "no-store" {
		http.Error(w, "invalid production request", http.StatusBadRequest)
		return true
	}
	if r.URL.Path == "/api-forbidden" || r.Header.Get("Authorization") == "Bearer old" {
		status := http.StatusUnauthorized
		if r.URL.Path == "/api-forbidden" {
			status = http.StatusForbidden
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, `{"error":"Unauthorized","code":401,"message":"expired"}`)
		return true
	}
	switch r.Header.Get("Content-Type") {
	case "application/json":
		if !json.Valid(body) || r.Header.Get("X-Luxo-Mode") != "" {
			http.Error(w, "invalid JSON request", http.StatusBadRequest)
			return true
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"data":42}`)
	case "application/x-luxo":
		if r.Header.Get("X-Luxo-Mode") != "binary" {
			http.Error(w, "missing binary mode", http.StatusBadRequest)
			return true
		}
		w.Header().Set("Content-Type", "application/x-luxo")
		_, _ = w.Write([]byte{84})
	default:
		http.Error(w, "invalid content type", http.StatusBadRequest)
	}
	return true
}
