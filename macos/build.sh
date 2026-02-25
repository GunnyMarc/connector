#!/usr/bin/env zsh
# build.sh — Build, test, and run the Connector macOS application.
#
# Usage:
#   ./build.sh --build          Build the app (Debug)
#   ./build.sh --release        Build the app (Release)
#   ./build.sh --test           Run the test suite
#   ./build.sh --run            Build (Debug) and launch the app
#   ./build.sh --clean          Remove Xcode derived data for this project
#   ./build.sh --generate       Regenerate Xcode project from project.yml
set -euo pipefail

SCRIPT_DIR="${0:a:h}"
cd "$SCRIPT_DIR"

PROJECT="Connector.xcodeproj"
SCHEME="Connector"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

# ── Helpers ────────────────────────────────────────────────────────────────────

app_path() {
    local config="${1:-Debug}"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$config" \
        -showBuildSettings 2>/dev/null \
        | grep -m1 "BUILT_PRODUCTS_DIR" \
        | awk '{print $3}'
}

print_header() {
    echo "──────────────────────────────────────────"
    echo "  $1"
    echo "──────────────────────────────────────────"
}

# ── Commands ───────────────────────────────────────────────────────────────────

do_build() {
    local config="${1:-Debug}"
    print_header "Building Connector ($config)"

    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -configuration "$config" build 2>&1 \
        | tail -5

    echo ""
    echo "Build ($config) complete."
}

do_test() {
    print_header "Running Tests"

    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -configuration Debug test 2>&1 \
        | grep -E "^(Test |✔|✘|Executed|\*\*)" \
        || true

    echo ""
}

do_run() {
    do_build "Debug"

    local products
    products="$(app_path Debug)"
    local app="$products/Connector.app"

    if [[ ! -d "$app" ]]; then
        echo "Error: Connector.app not found at $products"
        exit 1
    fi

    print_header "Launching Connector"
    open "$app"
}

do_clean() {
    print_header "Cleaning Derived Data"

    # Find and remove only this project's derived data.
    local found=false
    for dir in "$DERIVED_DATA"/Connector-*; do
        if [[ -d "$dir" ]]; then
            echo "Removing $dir"
            rm -rf "$dir"
            found=true
        fi
    done

    if [[ "$found" == false ]]; then
        echo "No derived data found for Connector."
    fi

    echo ""
    echo "Clean complete."
}

do_generate() {
    print_header "Generating Xcode Project"

    if ! command -v xcodegen &>/dev/null; then
        echo "Error: xcodegen is not installed."
        echo "Install it with: brew install xcodegen"
        exit 1
    fi

    xcodegen generate --spec project.yml
    echo ""
    echo "Project regenerated from project.yml."
}

show_usage() {
    echo "Usage: ./build.sh <option>"
    echo ""
    echo "Options:"
    echo "  --build      Build the app in Debug configuration"
    echo "  --release    Build the app in Release configuration"
    echo "  --test       Run the unit test suite"
    echo "  --run        Build (Debug) and launch the app"
    echo "  --clean      Remove Xcode derived data for this project"
    echo "  --generate   Regenerate Xcode project from project.yml (requires xcodegen)"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────

if [[ $# -eq 0 ]]; then
    show_usage
    exit 1
fi

case "$1" in
    --build)    do_build "Debug" ;;
    --release)  do_build "Release" ;;
    --test)     do_test ;;
    --run)      do_run ;;
    --clean)    do_clean ;;
    --generate) do_generate ;;
    *)
        echo "Unknown option: $1"
        echo ""
        show_usage
        exit 1
        ;;
esac
