# syntax=docker/dockerfile:1

ARG NODE_IMAGE=node:24.18.0-bookworm
ARG BASE_IMAGE=debian:13
ARG FIXUID_VERSION=0.6.0
ARG VERSION=0.0.0
ARG VSCODE_COMMIT=3a03d6f72d628a7741c29f456b4ddbb5ae68502c
ARG DEBIAN_FRONTEND=noninteractive
ARG USER_UID=1000
ARG USER_GID=1000

FROM ${NODE_IMAGE} AS builder

ARG DEBIAN_FRONTEND
ARG VERSION
ARG VSCODE_COMMIT

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    git-lfs \
    jq \
    libkrb5-dev \
    libsecret-1-dev \
    libx11-dev \
    libxkbfile-dev \
    python-is-python3 \
    quilt \
    rsync \
    unzip \
  && git lfs install \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# Use the local submodule content when available; otherwise fetch the exact
# VS Code commit pinned by this code-server revision.
RUN if [ ! -f lib/vscode/package.json ]; then \
    rm -rf lib/vscode; \
    git init lib/vscode; \
    git -C lib/vscode remote add origin https://github.com/microsoft/vscode.git; \
    git -C lib/vscode fetch --depth=1 origin "${VSCODE_COMMIT}"; \
    git -C lib/vscode checkout --detach FETCH_HEAD; \
  fi

# Docker does not need the host's Git metadata.  Minimal local repositories
# provide the commit and checkout operations used by the upstream build scripts.
RUN git init \
  && git config user.email builder@localhost \
  && git config user.name builder \
  && git add package.json \
  && git commit -m source-build \
  && quilt push -a \
  && if ! git -C lib/vscode rev-parse --git-dir >/dev/null 2>&1; then \
    git -C lib/vscode init; \
    git -C lib/vscode config user.email builder@localhost; \
    git -C lib/vscode config user.name builder; \
    git -C lib/vscode add product.json; \
    git -C lib/vscode commit -m patched-product; \
  fi

RUN npm ci
RUN npm run build
RUN VERSION="${VERSION}" npm run build:vscode
RUN KEEP_MODULES=1 npm run release

FROM ${BASE_IMAGE} AS runtime

ARG DEBIAN_FRONTEND
ARG FIXUID_VERSION
ARG USER_UID
ARG USER_GID

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash-completion \
    build-essential \
    ca-certificates \
    ccache \
    clang \
    clang-format \
    clang-tidy \
    clangd \
    cmake \
    curl \
    dnsutils \
    dumb-init \
    doxygen \
    dia \
    g++ \
    gcc \
    gdb \
    gdbserver \
    git \
    git-lfs \
    golang-go \
    graphviz \
    iproute2 \
    iputils-ping \
    jq \
    libeigen3-dev \
    libgsl-dev \
    libsqlite3-dev \
    libxml2-dev \
    make \
    nano \
    net-tools \
    ninja-build \
    nodejs \
    npm \
    openjdk-21-jdk \
    openssh-client \
    pkg-config \
    procps \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    ripgrep \
    rsync \
    shellcheck \
    sudo \
    tcpdump \
    tmux \
    tree \
    unzip \
    valgrind \
    vim \
    wget \
    zip \
    zsh \
  && git lfs install \
  && rm -rf /var/lib/apt/lists/*

RUN architecture="$(dpkg --print-architecture)" \
  && curl -fsSL "https://github.com/boxboat/fixuid/releases/download/v${FIXUID_VERSION}/fixuid-${FIXUID_VERSION}-linux-${architecture}.tar.gz" \
    | tar -C /usr/local/bin -xzf - \
  && chown root:root /usr/local/bin/fixuid \
  && chmod 4755 /usr/local/bin/fixuid

RUN if getent passwd 1000 >/dev/null; then \
    userdel -r "$(id -un 1000)"; \
  fi \
  && adduser --uid 1000 --gecos "" --disabled-password coder \
  && mkdir -p /etc/fixuid \
  && printf "user: coder\ngroup: coder\n" >/etc/fixuid/config.yml

# Match the container user with the host to keep bind-mounted files writable.
RUN set -eux; \
  current_uid="$(id -u coder)"; \
  current_gid="$(id -g coder)"; \
  if [ "${current_gid}" != "${USER_GID}" ]; then \
    existing_group="$(getent group "${USER_GID}" | cut -d: -f1 || true)"; \
    if [ -n "${existing_group}" ] && [ "${existing_group}" != "coder" ]; then \
      groupdel "${existing_group}"; \
    fi; \
    groupmod --gid "${USER_GID}" coder; \
  fi; \
  if [ "${current_uid}" != "${USER_UID}" ]; then \
    existing_user="$(getent passwd "${USER_UID}" | cut -d: -f1 || true)"; \
    if [ -n "${existing_user}" ] && [ "${existing_user}" != "coder" ]; then \
      userdel --remove "${existing_user}"; \
    fi; \
    usermod --uid "${USER_UID}" --gid "${USER_GID}" coder; \
  fi; \
  chown -R coder:coder /home/coder

RUN printf '%s\n' 'coder ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/coder \
  && chmod 0440 /etc/sudoers.d/coder

COPY --from=builder /src/release /opt/code-server
COPY ci/release-image/entrypoint.sh /usr/local/bin/code-server-entrypoint

RUN ln -s /opt/code-server/bin/code-server /usr/bin/code-server \
  && chmod 0755 /usr/local/bin/code-server-entrypoint \
  && mkdir -p \
    /workspace \
    /home/coder/.cache/ccache \
    /home/coder/.config/code-server \
    /home/coder/.local/share/code-server \
    /home/coder/.ssh \
    /home/coder/entrypoint.d \
  && chown -R coder:coder /workspace /home/coder

ENV ENTRYPOINTD=/home/coder/entrypoint.d
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV EDITOR=vim
ENV VISUAL=vim
ENV CCACHE_DIR=/home/coder/.cache/ccache

USER coder
WORKDIR /workspace

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/code-server-entrypoint"]
CMD ["--bind-addr", "0.0.0.0:8080", "."]
