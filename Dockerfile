# Enable GPU support – DEAKTIVIERT
# ARG GPU  ← entfernt

# Cross-compiling using Docker multi-platform builds/images and `xx`.
FROM --platform=${BUILDPLATFORM:-linux/amd64} tonistiigi/xx AS xx

# Utilize Docker layer caching with `cargo-chef`.
FROM --platform=${BUILDPLATFORM:-linux/amd64} lukemathwalker/cargo-chef:latest-rust-1.86.0 AS chef

FROM chef AS planner
WORKDIR /qdrant
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
WORKDIR /qdrant

COPY --from=xx / /

RUN apt-get update \
    && apt-get install -y clang lld cmake protobuf-compiler jq \
    && rustup component add rustfmt

ARG BUILDPLATFORM
ENV BUILDPLATFORM=${BUILDPLATFORM:-linux/amd64}

ARG MOLD_VERSION=2.36.0
RUN case "$BUILDPLATFORM" in \
        */amd64 ) PLATFORM=x86_64 ;; \
        */arm64 | */arm64/* ) PLATFORM=aarch64 ;; \
        * ) echo "Unexpected BUILDPLATFORM '$BUILDPLATFORM'" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/mold; \
    cd /opt/mold; \
    TARBALL="mold-$MOLD_VERSION-$PLATFORM-linux.tar.gz"; \
    curl -sSLO "https://github.com/rui314/mold/releases/download/v$MOLD_VERSION/$TARBALL"; \
    tar -xf "$TARBALL" --strip-components 1; \
    rm "$TARBALL"

ARG TARGETPLATFORM
ENV TARGETPLATFORM=${TARGETPLATFORM:-linux/amd64}

RUN xx-apt-get install -y pkg-config gcc g++ libc6-dev libunwind-dev

ARG PROFILE=release
ARG FEATURES
ARG RUSTFLAGS
ARG LINKER=mold

COPY --from=planner /qdrant/recipe.json recipe.json

RUN PKG_CONFIG="/usr/bin/$(xx-info)-pkg-config" \
    PATH="$PATH:/opt/mold/bin" \
    RUSTFLAGS="${LINKER:+-C link-arg=-fuse-ld=}$LINKER $RUSTFLAGS" \
    xx-cargo chef cook --profile $PROFILE ${FEATURES:+--features} $FEATURES --features=stacktrace --recipe-path recipe.json

COPY . .

ARG GIT_COMMIT_ID

RUN PKG_CONFIG="/usr/bin/$(xx-info)-pkg-config" \
    PATH="$PATH:/opt/mold/bin" \
    RUSTFLAGS="${LINKER:+-C link-arg=-fuse-ld=}$LINKER $RUSTFLAGS" \
    xx-cargo build --profile $PROFILE ${FEATURES:+--features} $FEATURES --features=stacktrace --bin qdrant \
    && PROFILE_DIR=$(if [ "$PROFILE" = dev ]; then echo debug; else echo $PROFILE; fi) \
    && mv target/$(xx-cargo --print-target-triple)/$PROFILE_DIR/qdrant /qdrant/qdrant

RUN mkdir /static && STATIC_DIR=/static ./tools/sync-web-ui.sh

# FINAL STAGE (CPU ONLY)
FROM debian:12-slim AS qdrant

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tzdata libunwind8 \
    && rm -rf /var/lib/apt/lists/*

ARG PACKAGES
RUN apt-get install -y --no-install-recommends $PACKAGES || true

ARG SOURCES
ENV DIR=${SOURCES:+/qdrant/src}
COPY --from=builder ${DIR:-/null?} $DIR/
ENV DIR=${SOURCES:+/qdrant/lib}
COPY --from=builder ${DIR:-/null?} $DIR/
ENV DIR=${SOURCES:+/usr/local/cargo/registry/src}
COPY --from=builder ${DIR:-/null?} $DIR/
ENV DIR=${SOURCES:+/usr/local/cargo/git/checkouts}
COPY --from=builder ${DIR:-/null?} $DIR/
ENV DIR=

ARG APP=/qdrant
COPY --from=builder /qdrant/qdrant "$APP"/qdrant
COPY --from=builder /qdrant/config "$APP"/config
COPY --from=builder /qdrant/tools/entrypoint.sh "$APP"/entrypoint.sh
COPY --from=builder /static "$APP"/static

WORKDIR "$APP"

ARG USER_ID=0
RUN if [ "$USER_ID" != 0 ]; then \
        groupadd --gid "$USER_ID" qdrant; \
        useradd --uid "$USER_ID" --gid "$USER_ID" -m qdrant; \
        mkdir -p "$APP"/storage "$APP"/snapshots; \
        chown -R "$USER_ID:$USER_ID" "$APP"; \
    fi

USER "$USER_ID:$USER_ID"

ENV TZ=Etc/UTC \
    RUN_MODE=production \
    QDRANT__SERVICE__HTTP_PORT=80

EXPOSE 80
EXPOSE 6334

LABEL org.opencontainers.image.title="Qdrant"
LABEL org.opencontainers.image.description="Official Qdrant image (CPU-only)"
LABEL org.opencontainers.image.url="https://qdrant.com/"
LABEL org.opencontainers.image.documentation="https://qdrant.com/docs"
LABEL org.opencontainers.image.source="https://github.com/qdrant/qdrant"
LABEL org.opencontainers.image.vendor="Qdrant"

CMD ["./entrypoint.sh"]
