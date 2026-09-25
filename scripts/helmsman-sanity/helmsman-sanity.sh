#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${ROOT_DIR}/common.sh"
source "${ROOT_DIR}/lib/discovery.sh"

main() {

    framework::initialize

    discovery::run

    framework::shutdown
}

main "$@"