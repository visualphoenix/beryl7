FROM debian:bookworm-slim

# Optional: drop corporate root CAs into extra-cas/ to have them
# trusted inside the build, needed behind an HTTPS MITM proxy. Empty by default,
# in which case nothing extra is trusted and the build still works.
COPY extra-cas/ /tmp/extra-cas/

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && for cert in /tmp/extra-cas/*.pem /tmp/extra-cas/*.crt; do \
         [ -f "$cert" ] || continue; \
         cp "$cert" "/usr/local/share/ca-certificates/$(basename "${cert%.*}").crt"; \
       done \
    && update-ca-certificates \
    && rm -rf /tmp/extra-cas \
    && apt-get install -y --no-install-recommends \
    build-essential \
    clang \
    flex \
    bison \
    g++ \
    gawk \
    gettext \
    git \
    libelf-dev \
    libncurses-dev \
    libssl-dev \
    python3-setuptools \
    python3-distutils \
    rsync \
    swig \
    unzip \
    zlib1g-dev \
    file \
    wget \
    curl \
    xz-utils \
    zstd \
    quilt \
    patch \
    device-tree-compiler \
    python3 \
    perl \
    time \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m builder
USER builder
WORKDIR /workdir
