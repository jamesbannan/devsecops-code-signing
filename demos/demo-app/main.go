package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

// Build metadata injected at compile time via -ldflags.
// Example: go build -ldflags="-X main.gitSHA=$(git rev-parse --short HEAD) -X main.buildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
var (
	version   = "1.0.0"
	gitSHA    = "unknown"
	buildTime = "unknown"
)

// BuildInfo is the JSON response for GET /
type BuildInfo struct {
	Version string `json:"version"`
	SHA     string `json:"sha"`
	Built   string `json:"built"`
	// Signed reflects the IMAGE_SIGNED environment variable.
	// Set IMAGE_SIGNED=true in the Pod spec to visually distinguish
	// signed deployments from unsigned ones during the demo.
	Signed bool `json:"signed"`
}

func main() {
	signed := os.Getenv("IMAGE_SIGNED") == "true"

	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(BuildInfo{
			Version: version,
			SHA:     gitSHA,
			Built:   buildTime,
			Signed:  signed,
		}); err != nil {
			log.Printf("encode error: %v", err)
		}
	})

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}` + "\n"))
	})

	addr := ":8080"
	log.Printf("demo-app starting on %s (version=%s sha=%s built=%s signed=%v)",
		addr, version, gitSHA, buildTime, signed)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
