# =============================================================================
# Dockerfile — DevSecOps demo application (multi-stage build)
# =============================================================================
# Stage 1: Build with golang:1.22-alpine
# Stage 2: Runtime with alpine:3.19 (minimal attack surface)
#
# Build args:
#   GIT_SHA    — injected by build-and-push.sh via git rev-parse
#   BUILD_TIME — injected by build-and-push.sh via date
# =============================================================================

# --- Stage 1: Build ---
FROM golang:1.22-alpine AS builder

WORKDIR /app

# Copy source
COPY go.mod .
COPY main.go .

# Build args for reproducibility metadata
ARG GIT_SHA=unknown
ARG BUILD_TIME=unknown

RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.gitSHA=${GIT_SHA} -X main.buildTime=${BUILD_TIME}" \
    -o demo-app \
    .

# --- Stage 2: Runtime ---
FROM alpine:3.19

# Non-root user for container security
RUN addgroup -S appgroup && adduser -S -G appgroup -u 1001 appuser

WORKDIR /app

# Copy binary from builder stage
COPY --from=builder /app/demo-app .

# Use non-root user
USER appuser

EXPOSE 8080

# Tini is not available in alpine by default; use the binary directly.
# The app handles SIGTERM gracefully via Go's http.Server default behaviour.
CMD ["./demo-app"]
