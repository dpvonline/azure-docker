# Caddy has no rate limiting in its core; mholt/caddy-ratelimit is the
# maintained module for it. Built with xcaddy in a throwaway stage so the final
# image stays the plain alpine one plus a replaced binary.
#
# Both stages track the same Caddy minor (Renovate bumps the two FROM lines
# together — see renovate.json). A module that stops compiling against a new
# Caddy release fails the build in update-containers.sh, which then rolls back.
FROM caddy:2.11-builder-alpine AS builder
RUN xcaddy build --with github.com/mholt/caddy-ratelimit

FROM caddy:2.11-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
