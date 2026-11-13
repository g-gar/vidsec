#!/usr/bin/env bash
# =============================================================================
# MangaDex Pipeline Execution Script
# Orchestrates build, pre-flight verification, permissions, and execution
# of Flowdata pipelines for MangaDex.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Auto-source .env if present (prefer root .env over configs/.env)
ENV_FILE=""
for candidate in "configs/.env" ".env"; do
    if [[ -f "$candidate" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$candidate"
        set +a
        ENV_FILE="$candidate"
    fi
done

PIPELINE_PATH="configs/pipeline.yaml"
MODE="run"
DO_BUILD=false
EXTRA_ARGS=()

usage() {
    cat <<EOF
Usage: ./run_pipeline.sh [options] [-- <extra_args>]

Options:
  -p, --pipeline <path>   Path to pipeline YAML (default: configs/pipeline.yaml)
  -v, --validate          Run pre-flight validation only (do not execute)
  -b, --build             Force rebuild of binary and shared plugin library
  -s, --serve             Start pipeline in server/daemon mode
  -h, --help              Show this help message

Examples:
  ./run_pipeline.sh                        # Validate and run default pipeline
  ./run_pipeline.sh --validate             # Check syntax, DAG, and plugins
  ./run_pipeline.sh -p configs/custom.yaml # Run custom pipeline
EOF
    exit 0
}

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--pipeline)
            PIPELINE_PATH="$2"
            shift 2
            ;;
        -v|--validate)
            MODE="validate"
            shift
            ;;
        -b|--build)
            DO_BUILD=true
            shift
            ;;
        -s|--serve)
            MODE="serve"
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            EXTRA_ARGS+=("$@")
            break
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

BIN_PATH="$SCRIPT_DIR/zig-out/bin/mangadex"
LIB_DIR="$SCRIPT_DIR/zig-out/lib"

# 1. Build if binaries are missing or if --build was requested
if [[ "$DO_BUILD" == true || ! -f "$BIN_PATH" || ! -d "$LIB_DIR" ]]; then
    echo "==> Building MangaDex binary and plugin library (zig build)..."
    zig build
fi

# 2. Ensure output directory structure exists for artifacts, databases, and logs
mkdir -p "$SCRIPT_DIR/output/logs" "$SCRIPT_DIR/output/cbz"

# 3. Enforce secure permissions on shared libraries (.so) required by Flowdata ABI security policy
if [[ -d "$LIB_DIR" ]]; then
    chmod 755 "$LIB_DIR"/*.so 2>/dev/null || true
fi

# 3. Verify pipeline file exists
if [[ ! -f "$PIPELINE_PATH" ]]; then
    echo "Error: Pipeline file '$PIPELINE_PATH' not found." >&2
    exit 1
fi

ENV_ARGS=()
if [[ -n "$ENV_FILE" ]]; then
    ENV_ARGS=(--env "$ENV_FILE")
fi

# 4. Dispatch selected mode
case "$MODE" in
    validate)
        echo "==> Validating pipeline '$PIPELINE_PATH'..."
        exec "$BIN_PATH" validate --pipeline "$PIPELINE_PATH" "${ENV_ARGS[@]}" "${EXTRA_ARGS[@]}"
        ;;
    serve)
        echo "==> Starting pipeline server with '$PIPELINE_PATH'..."
        exec "$BIN_PATH" serve --pipeline "$PIPELINE_PATH" "${ENV_ARGS[@]}" "${EXTRA_ARGS[@]}"
        ;;
    run)
        echo "==> Validating pre-flight requirements..."
        "$BIN_PATH" validate --pipeline "$PIPELINE_PATH" "${ENV_ARGS[@]}"

        echo "==> Executing pipeline '$PIPELINE_PATH'..."
        exec "$BIN_PATH" run --pipeline "$PIPELINE_PATH" "${ENV_ARGS[@]}" "${EXTRA_ARGS[@]}"
        ;;
esac
