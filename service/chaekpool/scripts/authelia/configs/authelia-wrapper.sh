#!/bin/sh
# Authelia wrapper script for supervise-daemon

export AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY_FILE="/etc/authelia/oidc.jwks.rsa.4096.pem"

exec /usr/local/bin/authelia --config /etc/authelia/configuration.yml
