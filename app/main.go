// Command demo-app is a tiny, dependency-free HTTP service used across the
// kubernetes-labs exercises.
//
// It deliberately uses only the Go standard library so that the container image
// can be built offline and shipped on a `scratch` base layer. That in turn lets
// every manifest in this repository run with readOnlyRootFilesystem: true and a
// non-root UID without any extra plumbing.
//
// Endpoints:
//
//	GET  /               human readable index, echoes pod identity
//	GET  /healthz        liveness probe; fails only if the process is wedged
//	GET  /readyz         readiness probe; can be toggled at runtime
//	GET  /metrics        Prometheus text exposition format
//	GET  /api/info       JSON view of pod identity + config
//	POST /toggle-ready   flips readiness, for demonstrating rolling updates
//	GET  /burn?seconds=N burns CPU, used by the autoscaling lab
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// version is overridden at build time via
// -ldflags "-X main.version=$(VERSION)". It must be a var, not a const: the
// linker can only rewrite variables.
var version = "1.0.0"

// -----------------------------------------------------------------------------
// metrics
// -----------------------------------------------------------------------------

// registry is a hand-rolled, allocation-light Prometheus registry. Using the
// official client_golang library would be the production choice; here we avoid
// it purely to keep the module dependency-free and the image tiny.
type registry struct {
	mu sync.Mutex

	requestsTotal map[labelKey]uint64
	durationSum   map[labelKey]float64
	// Fixed histogram buckets, in seconds.
	durationBuckets map[labelKey][]uint64

	readyGauge  atomic.Bool
	startedAt   time.Time
	burnSeconds atomic.Uint64
}

type labelKey struct {
	method string
	path   string
	status int
}

var buckets = []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

func newRegistry() *registry {
	r := &registry{
		requestsTotal:   make(map[labelKey]uint64),
		durationSum:     make(map[labelKey]float64),
		durationBuckets: make(map[labelKey][]uint64),
		startedAt:       time.Now(),
	}
	r.readyGauge.Store(true)
	return r
}

func (r *registry) observe(method, path string, status int, d time.Duration) {
	k := labelKey{method: method, path: path, status: status}

	r.mu.Lock()
	defer r.mu.Unlock()

	r.requestsTotal[k]++
	r.durationSum[k] += d.Seconds()

	b, ok := r.durationBuckets[k]
	if !ok {
		b = make([]uint64, len(buckets))
		r.durationBuckets[k] = b
	}
	secs := d.Seconds()
	for i, upper := range buckets {
		if secs <= upper {
			b[i]++
		}
	}
}

// writeMetrics renders the Prometheus text exposition format (version 0.0.4).
func (r *registry) writeMetrics(w http.ResponseWriter) {
	r.mu.Lock()
	defer r.mu.Unlock()

	fmt.Fprintf(w, "# HELP demo_app_build_info Build information for the demo app.\n")
	fmt.Fprintf(w, "# TYPE demo_app_build_info gauge\n")
	fmt.Fprintf(w, "demo_app_build_info{version=%q,goversion=%q} 1\n", version, runtime.Version())

	fmt.Fprintf(w, "# HELP demo_app_uptime_seconds Seconds since process start.\n")
	fmt.Fprintf(w, "# TYPE demo_app_uptime_seconds gauge\n")
	fmt.Fprintf(w, "demo_app_uptime_seconds %g\n", time.Since(r.startedAt).Seconds())

	ready := 0
	if r.readyGauge.Load() {
		ready = 1
	}
	fmt.Fprintf(w, "# HELP demo_app_ready Whether the app reports itself ready (1) or not (0).\n")
	fmt.Fprintf(w, "# TYPE demo_app_ready gauge\n")
	fmt.Fprintf(w, "demo_app_ready %d\n", ready)

	fmt.Fprintf(w, "# HELP demo_app_cpu_burn_seconds_total Total seconds of synthetic CPU load generated.\n")
	fmt.Fprintf(w, "# TYPE demo_app_cpu_burn_seconds_total counter\n")
	fmt.Fprintf(w, "demo_app_cpu_burn_seconds_total %d\n", r.burnSeconds.Load())

	fmt.Fprintf(w, "# HELP demo_app_goroutines Current number of goroutines.\n")
	fmt.Fprintf(w, "# TYPE demo_app_goroutines gauge\n")
	fmt.Fprintf(w, "demo_app_goroutines %d\n", runtime.NumGoroutine())

	fmt.Fprintf(w, "# HELP demo_app_http_requests_total Total HTTP requests handled.\n")
	fmt.Fprintf(w, "# TYPE demo_app_http_requests_total counter\n")
	for k, v := range r.requestsTotal {
		fmt.Fprintf(w, "demo_app_http_requests_total{method=%q,path=%q,status=%q} %d\n",
			k.method, k.path, strconv.Itoa(k.status), v)
	}

	fmt.Fprintf(w, "# HELP demo_app_http_request_duration_seconds HTTP request latency.\n")
	fmt.Fprintf(w, "# TYPE demo_app_http_request_duration_seconds histogram\n")
	for k, b := range r.durationBuckets {
		// observe() already increments every bucket whose upper bound the
		// observation falls under, so b[i] is cumulative by construction -
		// which is exactly what the "le" semantics require.
		for i, upper := range buckets {
			fmt.Fprintf(w,
				"demo_app_http_request_duration_seconds_bucket{method=%q,path=%q,status=%q,le=%q} %d\n",
				k.method, k.path, strconv.Itoa(k.status), strconv.FormatFloat(upper, 'g', -1, 64), b[i])
		}
		total := r.requestsTotal[k]
		fmt.Fprintf(w,
			"demo_app_http_request_duration_seconds_bucket{method=%q,path=%q,status=%q,le=\"+Inf\"} %d\n",
			k.method, k.path, strconv.Itoa(k.status), total)
		fmt.Fprintf(w,
			"demo_app_http_request_duration_seconds_sum{method=%q,path=%q,status=%q} %g\n",
			k.method, k.path, strconv.Itoa(k.status), r.durationSum[k])
		fmt.Fprintf(w,
			"demo_app_http_request_duration_seconds_count{method=%q,path=%q,status=%q} %d\n",
			k.method, k.path, strconv.Itoa(k.status), total)
	}
}

// -----------------------------------------------------------------------------
// server
// -----------------------------------------------------------------------------

type server struct {
	reg *registry
	log *slog.Logger

	podName   string
	nodeName  string
	namespace string
	message   string
	// apiKey is sourced from a Secret in lab 03. Never logged, never echoed in
	// full - we only ever expose a redacted fingerprint.
	apiKey string
}

// statusRecorder captures the status code so the metrics middleware can label
// on it. http.ResponseWriter gives us no way to read it back.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

// instrument wraps a handler with metrics and structured access logging.
func (s *server) instrument(path string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w}

		next(rec, r)

		if rec.status == 0 {
			rec.status = http.StatusOK
		}
		elapsed := time.Since(start)
		s.reg.observe(r.Method, path, rec.status, elapsed)

		// The /metrics endpoint is scraped every few seconds; logging it would
		// drown out everything useful.
		if path != "/metrics" {
			s.log.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", rec.status,
				"duration_ms", elapsed.Milliseconds(),
				"remote", r.RemoteAddr,
			)
		}
	}
}

func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.instrument("/", s.handleIndex))
	mux.HandleFunc("/healthz", s.instrument("/healthz", s.handleHealthz))
	mux.HandleFunc("/readyz", s.instrument("/readyz", s.handleReadyz))
	mux.HandleFunc("/metrics", s.instrument("/metrics", s.handleMetrics))
	mux.HandleFunc("/api/info", s.instrument("/api/info", s.handleInfo))
	mux.HandleFunc("/toggle-ready", s.instrument("/toggle-ready", s.handleToggleReady))
	mux.HandleFunc("/burn", s.instrument("/burn", s.handleBurn))
	return mux
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	// ServeMux's "/" pattern is a catch-all, so anything unrouted lands here.
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintf(w, "%s\n\n", s.message)
	fmt.Fprintf(w, "version:   %s\n", version)
	fmt.Fprintf(w, "pod:       %s\n", s.podName)
	fmt.Fprintf(w, "namespace: %s\n", s.namespace)
	fmt.Fprintf(w, "node:      %s\n", s.nodeName)
	fmt.Fprintf(w, "ready:     %t\n", s.reg.readyGauge.Load())
	fmt.Fprintf(w, "uptime:    %s\n", time.Since(s.reg.startedAt).Truncate(time.Second))
}

// handleHealthz is the liveness probe. It must only fail when the process is
// genuinely unrecoverable - a liveness probe that fails on downstream errors
// turns a partial outage into a crash loop.
func (s *server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"status": "ok",
		"uptime": time.Since(s.reg.startedAt).String(),
	})
}

// handleReadyz is the readiness probe. Unlike liveness it is allowed - expected,
// even - to flap: it gates traffic, not restarts.
func (s *server) handleReadyz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if !s.reg.readyGauge.Load() {
		w.WriteHeader(http.StatusServiceUnavailable)
		_ = json.NewEncoder(w).Encode(map[string]any{"status": "not ready"})
		return
	}
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]any{"status": "ready"})
}

func (s *server) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	s.reg.writeMetrics(w)
}

func (s *server) handleInfo(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"version":     version,
		"pod":         s.podName,
		"namespace":   s.namespace,
		"node":        s.nodeName,
		"message":     s.message,
		"ready":       s.reg.readyGauge.Load(),
		"uptime":      time.Since(s.reg.startedAt).String(),
		"api_key_set": s.apiKey != "",
		// Only a fingerprint - the actual secret never leaves the process.
		"api_key_fingerprint": fingerprint(s.apiKey),
	})
}

func (s *server) handleToggleReady(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	newState := !s.reg.readyGauge.Load()
	s.reg.readyGauge.Store(newState)
	s.log.Warn("readiness toggled", "ready", newState)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ready": newState})
}

// handleBurn generates synthetic CPU load so the HPA in lab 06 has something to
// react to. It is capped so a stray request cannot pin a node indefinitely.
func (s *server) handleBurn(w http.ResponseWriter, r *http.Request) {
	seconds := 5
	if v := r.URL.Query().Get("seconds"); v != "" {
		parsed, err := strconv.Atoi(v)
		if err != nil || parsed < 1 {
			http.Error(w, "seconds must be a positive integer", http.StatusBadRequest)
			return
		}
		seconds = parsed
	}
	if seconds > 60 {
		seconds = 60
	}

	deadline := time.Now().Add(time.Duration(seconds) * time.Second)
	for time.Now().Before(deadline) {
		// Tight arithmetic loop; the compiler cannot elide it because x escapes
		// via the sink below.
		x := 0
		for i := 0; i < 5_000_000; i++ {
			x += i % 7
		}
		_ = x
	}
	s.reg.burnSeconds.Add(uint64(seconds))

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"burned_seconds": seconds})
}

// fingerprint returns a short, non-reversible hint that a secret is present and
// which one it is, without disclosing the value.
func fingerprint(s string) string {
	if s == "" {
		return ""
	}
	var h uint32 = 2166136261
	for i := 0; i < len(s); i++ {
		h ^= uint32(s[i])
		h *= 16777619
	}
	return fmt.Sprintf("%08x", h)
}

// -----------------------------------------------------------------------------
// wiring
// -----------------------------------------------------------------------------

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	addr := ":" + env("PORT", "8080")

	srv := &server{
		reg:       newRegistry(),
		log:       log,
		podName:   env("POD_NAME", "unknown"),
		nodeName:  env("NODE_NAME", "unknown"),
		namespace: env("POD_NAMESPACE", "default"),
		message:   env("GREETING", "Hello from the kubernetes-labs demo app!"),
		apiKey:    os.Getenv("API_KEY"),
	}

	httpServer := &http.Server{
		Addr:    addr,
		Handler: srv.routes(),
		// Timeouts are mandatory in production: without them a slow client can
		// hold a connection - and a goroutine - open forever.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      90 * time.Second, // generous: /burn can run 60s
		IdleTimeout:       60 * time.Second,
	}

	// Graceful shutdown. Kubernetes sends SIGTERM, waits terminationGracePeriod,
	// then SIGKILLs. We flip readiness to false immediately so endpoints
	// controllers pull us out of Service rotation before we stop accepting.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Info("listening", "addr", addr, "version", version, "pod", srv.podName)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	log.Info("shutdown signal received, draining")
	srv.reg.readyGauge.Store(false)

	// Give load balancers a moment to observe the failing readiness probe
	// before we stop serving. 5s comfortably exceeds the 2s probe period used
	// by the manifests in this repo.
	time.Sleep(5 * time.Second)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}
	log.Info("shutdown complete")
}
