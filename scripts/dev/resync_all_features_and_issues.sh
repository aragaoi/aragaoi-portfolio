#!/bin/bash

# Synchronizes all features with GitHub issues
# - Scans all module READMEs for uncompleted features
# - Creates missing issues for features
# - Updates issue statuses based on feature completion
# - Requires GITHUB_TOKEN and GITHUB_REPOSITORY in .env file

set -e # Exit on error

# Load environment variables from .env file
if [ -f "$(dirname "$0")/../../.env" ]; then
    export $(cat "$(dirname "$0")/../../.env" | grep -E "^(GITHUB_TOKEN|GITHUB_REPOSITORY)=" | xargs)
fi

# Validate required environment variables
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: GITHUB_TOKEN environment variable is not set"
    exit 1
fi

if [ -z "$GITHUB_REPOSITORY" ]; then
    echo "Error: GITHUB_REPOSITORY environment variable is not set"
    exit 1
fi

# Source common functions from create_issues.sh
source "$(dirname "$0")/../create_issues.sh"

# Function to resync a module's features
resync_module() {
    local module=$1
    local readme_file="shared-modules/$module/README.md"

    if [ ! -f "$readme_file" ]; then
        echo "Error: Module README not found: $readme_file"
        return 1
    fi

    local current_priority=""
    echo "Resyncing features for module: $module"

    while IFS= read -r line; do
        if [[ $line =~ ^"## Features"$ ]]; then
            continue
        elif [[ $line =~ ^"### "* ]] || [[ $line =~ ^"## "* ]]; then
            break
        elif [[ $line =~ ^"High Priority:"$ ]]; then
            current_priority="high"
        elif [[ $line =~ ^"Medium Priority:"$ ]]; then
            current_priority="medium"
        elif [[ $line =~ ^"Low Priority:"$ ]]; then
            current_priority="low"
        elif [[ $line =~ ^"- \[ \]"* ]]; then
            # Extract feature name
            local feature=$(echo "$line" | sed -E 's/- \[ \] (.*?)( +#.*)?$/\1/')

            # Skip if feature already has an issue link
            if [[ $line =~ "#[[:space:]]*issue:[[:space:]]*\[#[0-9]+\]" ]]; then
                echo "Feature already has issue link: $feature"
                continue
            fi

            echo "Creating issue for: $feature"
            create_github_issue "$module" "$feature" "$current_priority" "${module}_${feature// /_}" || return 1
        fi
    done <"$readme_file"
}

# Main execution
main() {
    echo "Starting feature resync process..."

    # Get all modules from README
    read -ra modules <<<"$(get_all_modules)"

    # Resync all modules
    for module in "${modules[@]}"; do
        resync_module "$module" || exit 1
    done

    echo "Feature resync process completed"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
