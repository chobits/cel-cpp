#!/bin/bash

set -euo pipefail

real_compiler="/usr/bin/clang"
ld64_path=""

for candidate in \
  "$(command -v ld64.lld 2>/dev/null || true)" \
  "/opt/homebrew/opt/llvm@15/bin/ld64.lld" \
  "/opt/homebrew/opt/llvm/bin/ld64.lld" \
  "/opt/homebrew/opt/llvm@16/bin/ld64.lld"; do
  if [[ -n "${candidate}" && -x "${candidate}" ]]; then
    ld64_path="${candidate}"
    break
  fi
done

args=()
for arg in "$@"; do
  case "$arg" in
    -fuse-ld=ld64.lld:)
      if [[ -n "${ld64_path}" ]]; then
        args+=("-fuse-ld=${ld64_path}")
      else
        args+=("$arg")
      fi
      ;;
    -fuse-ld=lld)
      if [[ -n "${ld64_path}" ]]; then
        args+=("-fuse-ld=${ld64_path}")
      else
        args+=("$arg")
      fi
      ;;
    *)
      args+=("$arg")
      ;;
  esac
done

stderr_file="$(mktemp)"
trap 'rm -f "${stderr_file}"' EXIT

set +e
"${real_compiler}" "${args[@]}" 2>"${stderr_file}"
status=$?
set -e

if [[ -s "${stderr_file}" ]]; then
  sed '/^ld64\.lld: warning: directory not found for option -L\/usr\/local\/lib$/d' "${stderr_file}" >&2
fi

exit "$status"