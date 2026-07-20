# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the kubernetes-labs demo app.
#
# Stage 1 compiles a fully static binary; stage 2 copies it onto `scratch`.
# The result is a ~6 MB image with no shell, no package manager and no libc -
# which is exactly what makes `readOnlyRootFilesystem: true` and a non-root UID
# trivial to enforce in every manifest in this repository.
#
# Build:
#   docker build -t ghcr.io/maneeshm/k8s-labs-demo:1.0.0 app/
# Load into kind:
#   kind load docker-image ghcr.io/maneeshm/k8s-labs-demo:1.0.0 --name k8s-labs

# -----------------------------------------------------------------------------
# Stage 1: build
# -----------------------------------------------------------------------------
FROM golang:1.22-alpine AS build

# Build-time metadata, injected by CI. Kept as ARGs so the layer cache is not
# invalidated for source-only rebuilds.
ARG VERSION=1.0.0
ARG TARGETOS=linux
ARG TARGETARCH=amd64

WORKDIR /src

# Copy the module definition first so `go mod download` is cached independently
# of the source. This module has zero third-party dependencies, so the download
# is a no-op today - but the layering is the habit worth keeping.
COPY go.mod ./
RUN go mod download

COPY main.go ./

# CGO_ENABLED=0 is what makes the binary static and therefore runnable on
# scratch. -trimpath strips local filesystem paths for reproducibility;
# -ldflags "-s -w" drops the symbol table and DWARF data.
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/demo-app \
      .

# Verify the binary really is static. If this ever prints a dynamic section the
# scratch image would fail at runtime with "no such file or directory" - a
# famously confusing error. Failing here instead is much kinder.
RUN if go tool nm /out/demo-app 2>/dev/null | grep -q ' T _cgo'; then \
      echo "ERROR: binary is not static (cgo symbols present)" >&2; exit 1; \
    fi

# -----------------------------------------------------------------------------
# Stage 2: runtime
# -----------------------------------------------------------------------------
FROM scratch AS runtime

# The app makes no outbound TLS calls today, but shipping the CA bundle costs a
# few hundred kilobytes and saves a painful debugging session the first time
# someone adds an HTTPS client.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

COPY --from=build /out/demo-app /demo-app

# 65532 is the conventional "nonroot" UID/GID used by distroless and by every
# manifest in this repo. Declaring it here means the container is non-root even
# if a manifest forgets to set runAsUser.
USER 65532:65532

EXPOSE 8080

ENV PORT=8080

# No shell exists in this image, so this is necessarily the exec form.
ENTRYPOINT ["/demo-app"]
