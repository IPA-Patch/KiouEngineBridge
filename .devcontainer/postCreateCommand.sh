#!/bin/sh

USER_NAME="$(whoami)"
USER_HOME="/home/${USER_NAME}"

sudo mkdir -p \
    "${USER_HOME}/app/.venv" \
    "${USER_HOME}/.cache/uv" \
    "${USER_HOME}/.cache/pip" \
    "${USER_HOME}/.bun/install/cache" \
    "${USER_HOME}/.npm"

sudo chown -R "${USER_NAME}":"${USER_NAME}" \
    "${USER_HOME}/app/.venv" \
    "${USER_HOME}/.cache/uv" \
    "${USER_HOME}/.cache/pip" \
    "${USER_HOME}/.bun/install/cache" \
    "${USER_HOME}/.npm"

uv sync
