#!/bin/sh
# Authelia wrapper script for supervise-daemon

exec /usr/local/bin/authelia --config /etc/authelia/configuration.yml --config.experimental.filters template
