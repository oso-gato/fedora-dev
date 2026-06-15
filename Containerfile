# fedora-dev — headless Fedora development container hosting a Distrobox-based
# claudebox (Claude Code daily-rebuilt from Anthropic's `latest` channel).
# Base image rebuilt MONTHLY by CI (15th, --no-cache); box rebuilt DAILY in-container.
# All packages from official sources only: Fedora repos + Tailscale's official dnf
# repo for the base; Anthropic's official dnf repo for Claude Code inside the box.
# No passwords in any layer — CORE_PASSWORD is injected at runtime.
ARG FEDORA_VERSION=44
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION}

COPY install.sh /tmp/install.sh
RUN bash /tmp/install.sh && rm /tmp/install.sh

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Box assembly seed — used by entrypoint on FIRST BOOT to seed the live git
# clone at /home/core/.local/share/fedora-dev/ if GitHub is unreachable. Once
# the live clone exists, this baked copy is ignored. The actual runtime spec
# is the live clone.
COPY distrobox.ini \
     claudebox-init.sh \
     box-rebuild.sh \
     claudebox-daily.sh \
     claudebox-assemble.sh \
     README.md \
     CLAUDE.md \
     /usr/local/share/fedora-dev/
COPY policy/ /usr/local/share/fedora-dev/policy/

# Operator wrappers (the only entry points from the outer tmux shell). Baked
# here because managed-settings.json denies runtime writes to /usr/local/bin.
COPY --chmod=755 bin/claude bin/claudebox-rebuild /usr/local/bin/

ENV LANG=en_US.UTF-8

VOLUME ["/home/core", "/var/lib/tailscale"]
# ssh :22 and mosh (UDP) are reached via the tailnet IP only — never publish them.
EXPOSE 22 60000-61000/udp
# No HEALTHCHECK: podman builds OCI images which silently drop it.
# Health is defined at run time — see run.sh (--health-cmd).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
