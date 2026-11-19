package main

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	if len(os.Args) != 3 {
		panic("certificate and key paths required")
	}
	var started, cancelled, http1Calls, overflowCancelled, redirectTargets atomic.Int64
	replay := &replayProbe{cases: make(map[string]replayCase)}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if replay.serve(w, r) || redirectAPI(w, r, &redirectTargets) || protocolAPI(w, r) {
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
	h1, h1Addr := start(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http1Calls.Add(1)
		if !replay.serve(w, r) && !redirectAPI(w, r, &redirectTargets) {
			protocolAPI(w, r)
		}
	}), false)
	_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"h2": h2Addr, "h1": h1Addr})
	_, _ = io.Copy(io.Discard, os.Stdin)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = h2.Shutdown(ctx)
	_ = h1.Shutdown(ctx)
}

type replayCase struct {
	count         int
	first, second string
}

type replayProbe struct {
	mu    sync.Mutex
	cases map[string]replayCase
}

func (p *replayProbe) serve(w http.ResponseWriter, r *http.Request) bool {
	if r.URL.Path != "/replay" {
		return false
	}
	key := r.Header.Get("X-Test-Case")
	if _, err := io.Copy(io.Discard, http.MaxBytesReader(w, r.Body, 2<<20)); err != nil || key == "" || r.Method != http.MethodPost {
		http.Error(w, "invalid replay probe", http.StatusBadRequest)
		return true
	}
	p.mu.Lock()
	entry := p.cases[key]
	probe := r.Header.Get("X-Test-Probe") == "true"
	if !probe {
		entry.count++
		if entry.count == 1 {
			entry.first = r.RemoteAddr
		} else if entry.count == 2 {
			entry.second = r.RemoteAddr
		}
		p.cases[key] = entry
	}
	p.mu.Unlock()
	if probe {
		_, _ = io.WriteString(w, strconv.Itoa(entry.count)+"\n"+entry.first+"\n"+entry.second)
		return true
	}
	action := r.Header.Get("X-Test-Action")
	if action == "codable" {
		writeCodableResponse(w, r)
		return true
	}
	if action == "lost" && entry.count == 2 {
		panic(http.ErrAbortHandler)
	}
	status := http.StatusOK
	if entry.count == 1 {
		switch action {
		case "408":
			status = http.StatusRequestTimeout
		case "503":
			status = http.StatusServiceUnavailable
		case "refresh":
			status = http.StatusUnauthorized
		}
	}
	writeReplayResponse(w, r, status)
	return true
}

func writeCodableResponse(w http.ResponseWriter, r *http.Request) {
	models, modelErr := strconv.Atoi(r.Header.Get("X-Test-Models"))
	depth, depthErr := strconv.Atoi(r.Header.Get("X-Test-JSON"))
	if modelErr != nil || depthErr != nil || models < 1 || models > 65 || depth < 0 || depth > 129 {
		http.Error(w, "invalid Codable depth probe", http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	var body strings.Builder
	body.WriteString(`{"data":`)
	body.WriteString(strings.Repeat(`{"child":`, models-1))
	body.WriteString(`{"metadata":`)
	body.WriteString(strings.Repeat("[", depth))
	body.WriteByte('7')
	body.WriteString(strings.Repeat("]", depth))
	body.WriteString(strings.Repeat("}", models+1))
	_, _ = io.WriteString(w, body.String())
}

func writeReplayResponse(w http.ResponseWriter, r *http.Request, status int) {
	if status == http.StatusUnauthorized {
		writeUnauthorized(w, r)
		return
	}
	if status == http.StatusOK {
		if r.Header.Get("Content-Type") == "application/json" {
			_, _ = io.WriteString(w, `{"data":42}`)
		} else {
			_, _ = w.Write([]byte{84})
		}
		return
	}
	w.Header().Set("Retry-After", "0")
	w.WriteHeader(status)
	if r.Header.Get("Content-Type") == "application/json" {
		_, _ = io.WriteString(w, `{"error":"Unavailable","code":`+strconv.Itoa(status)+`,"message":"retry later"}`)
		return
	}
	body := binary.AppendUvarint([]byte{1}, uint64(status*2))
	body = append(body, 2, byte(len("Unavailable")))
	body = append(body, "Unavailable"...)
	body = append(body, 3, byte(len("retry later")))
	body = append(body, "retry later"...)
	_, _ = w.Write(append(body, 0))
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

// redirectAPI records any replay at either TLS endpoint.
func redirectAPI(w http.ResponseWriter, r *http.Request, targets *atomic.Int64) bool {
	if r.URL.Path == "/redirect-target" {
		targets.Add(1)
		w.WriteHeader(http.StatusOK)
		return true
	}
	if r.URL.Path != "/redirect" {
		return false
	}
	_, _ = io.Copy(io.Discard, http.MaxBytesReader(w, r.Body, 2<<20))
	if r.Header.Get("X-Test-Refresh") == "true" && r.Header.Get("Authorization") == "Bearer old" {
		writeUnauthorized(w, r)
		return true
	}
	if r.Header.Get("X-Test-Status") == "" {
		_, _ = io.WriteString(w, strconv.FormatInt(targets.Load(), 10))
		return true
	}
	status, err := strconv.Atoi(r.Header.Get("X-Test-Status"))
	if err != nil || (status != 301 && status != 302 && status != 303 && status != 307 && status != 308) {
		http.Error(w, "invalid redirect status", 400)
		return true
	}
	w.Header().Set("Location", r.Header.Get("X-Test-Target"))
	w.WriteHeader(status)
	return true
}

func writeUnauthorized(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusUnauthorized)
	if r.Header.Get("Content-Type") == "application/json" {
		_, _ = io.WriteString(w, `{"error":"Unauthorized","code":401,"message":"expired"}`)
		return
	}
	// Error fields: code (signed varint), name, message, end.
	body := binary.AppendUvarint([]byte{1}, 401<<1)
	body = append(body, 2, 12)
	body = append(body, "Unauthorized"...)
	body = append(body, 3, 7)
	body = append(body, "expired"...)
	_, _ = w.Write(append(body, 0))
}
