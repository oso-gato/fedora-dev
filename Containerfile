# fedora-dev — headless Fedora development container for building other
# Fedora-based container images (nested rootless podman), accessed over the
# tailnet via ssh/mosh (every login lands in tmux). All packages from official sources only:
# Fedora repos, vendor dnf repos, or vendor-released .rpms.
# No passwords in any layer — CORE_PASSWORD is injected at runtime.
ARG FEDORA_VERSION=44
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION}

ARG RCLONE_VERSION=1.74.3

COPY install.sh /tmp/install.sh
RUN RCLONE_VERSION="${RCLONE_VERSION}" bash /tmp/install.sh && rm /tmp/install.sh

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Enterprise-tier Claude Code policy: highest-precedence law for any Claude
# Code session in this container (see claude-policy/CLAUDE.md).
COPY claude-policy/CLAUDE.md /etc/claude-code/CLAUDE.md
COPY claude-policy/managed-settings.json /etc/claude-code/managed-settings.json

ENV LANG=en_US.UTF-8

VOLUME ["/home/core", "/var/lib/tailscale"]
# ssh :22 and mosh (UDP) are reached via the tailnet IP only — never publish them.
EXPOSE 22 60000-61000/udp
# No HEALTHCHECK: podman builds OCI images which silently drop it.
# Health is defined at run time — see run.sh (--health-cmd).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
