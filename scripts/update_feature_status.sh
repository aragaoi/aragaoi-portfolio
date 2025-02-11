#!/bin/bash

# Updates feature completion status in README files based on GitHub issue state
# - Updates feature checkboxes when issues are closed/reopened
# - Syncs status between module README and main README
# - Called by GitHub Actions when issue status changes
# - Requires GITHUB_TOKEN and GITHUB_REPOSITORY in .env file

set -e # Exit on error

# Load environment variables from .env file
if [ -f "$(dirname "$0")/../.env" ]; then
    export $(cat "$(dirname "$0")/../.env" | grep -E "^(GITHUB_TOKEN|GITHUB_REPOSITORY)=" | xargs)
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

# Get issue details from environment variables
ISSUE_TITLE="$1"
ISSUE_STATE="$2"
ISSUE_NUMBER="$3"
REPO_OWNER=$(echo "$GITHUB_REPOSITORY" | cut -d'/' -f1)
REPO_NAME=$(echo "$GITHUB_REPOSITORY" | cut -d'/' -f2)

# Validate input parameters
if [ -z "$ISSUE_TITLE" ] || [ -z "$ISSUE_STATE" ] || [ -z "$ISSUE_NUMBER" ] || [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    echo "Error: Missing required parameters"
    echo "Usage: $0 <issue_title> <issue_state> <issue_number> <repo_owner> <repo_name>"
    exit 1
fi

if [ "$ISSUE_STATE" != "closed" ] && [ "$ISSUE_STATE" != "open" ]; then
    echo "Error: Invalid issue state: $ISSUE_STATE"
    exit 1
fi

# Extract module name from issue title [module] Feature Name
if [[ ! "$ISSUE_TITLE" =~ \[(.*?)\] ]]; then
    echo "Error: Invalid issue title format. Expected: [module] Feature Name"
    exit 1
fi

MODULE=$(echo "$ISSUE_TITLE" | sed -E 's/\[(.*?)\].*/\1/')
MODULE=$(echo "$MODULE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]*&[[:space:]]*//')

# Validate module exists
if [ ! -d "shared-modules/$MODULE" ]; then
    echo "Error: Module directory not found: shared-modules/$MODULE"
    exit 1
fi

# Function to update feature status in README
update_feature_status() {
    local file=$1
    local status=$2
    local temp_file="${file}.tmp"

    if [ ! -f "$file" ]; then
        echo "Error: File not found: $file"
        return 1
    fi

    # Create temp file
    >"$temp_file"

    local found_feature=false
    local issue_link="https://github.com/$REPO_OWNER/$REPO_NAME/issues/$ISSUE_NUMBER"

    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*-[[:space:]]*\[.*\].*#[[:space:]]*issue:[[:space:]]*\[#$ISSUE_NUMBER\]\(.*\) ]]; then
            # Found the line with our issue number
            found_feature=true
            if [ "$status" = "complete" ]; then
                echo "${line/\[ \]/\[x\]}" >>"$temp_file"
            else
                echo "${line/\[x\]/\[ \]}" >>"$temp_file"
            fi
        else
            echo "$line" >>"$temp_file"
        fi
    done <"$file"

    if [ "$found_feature" = false ]; then
        echo "Warning: No feature found with issue #$ISSUE_NUMBER in $file"
        rm "$temp_file"
        return 1
    fi

    # Validate temp file is not empty before moving
    if [ ! -s "$temp_file" ]; then
        echo "Error: Generated file is empty: $temp_file"
        rm "$temp_file"
        return 1
    fi

    mv "$temp_file" "$file"
}

# Update both main README and module README
if [ "$ISSUE_STATE" = "closed" ]; then
    update_feature_status "README.md" "complete" || exit 1
    update_feature_status "shared-modules/$MODULE/README.md" "complete" || exit 1
else
    update_feature_status "README.md" "incomplete" || exit 1
    update_feature_status "shared-modules/$MODULE/README.md" "incomplete" || exit 1
fi
