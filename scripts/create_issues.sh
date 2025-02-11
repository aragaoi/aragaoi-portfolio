#!/bin/bash

# Creates GitHub issues for features defined in module README files
# - Creates an issue for each uncompleted feature
# - Updates README files with issue links
# - Supports both direct feature creation and bulk scanning mode
# - Requires GITHUB_TOKEN and GITHUB_REPOSITORY in .env file

set -e  # Exit on error

# Load environment variables from .env file
if [ -f "$(dirname "$0")/../.env" ]; then
    export $(cat "$(dirname "$0")/../.env" | grep -E "^(GITHUB_TOKEN|GITHUB_REPOSITORY)=" | xargs)
fi

# GitHub configuration
GITHUB_API="https://api.github.com/repos/$GITHUB_REPOSITORY"

# Validate required environment variables
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: GITHUB_TOKEN environment variable is not set"
    exit 1
fi

if [ -z "$GITHUB_REPOSITORY" ]; then
    echo "Error: GITHUB_REPOSITORY environment variable is not set"
    exit 1
fi

# Function to validate API response
validate_response() {
    local response=$1
    local action=$2

    if [ -z "$response" ]; then
        echo "Error: Empty response from GitHub API during $action"
        return 1
    fi

    if echo "$response" | jq -e '.message' >/dev/null; then
        echo "Error during $action: $(echo "$response" | jq -r '.message')"
        return 1
    fi

    return 0
}

# Function to create GitHub issue if it doesn't exist
create_github_issue() {
    local module=$1
    local feature=$2
    local priority=$3
    local feature_id=$4

    # Validate input
    if [ -z "$module" ] || [ -z "$feature" ] || [ -z "$priority" ] || [ -z "$feature_id" ]; then
        echo "Error: Missing required parameters for create_github_issue"
        return 1
    fi

    # Check if issue exists by feature ID label
    local response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "$GITHUB_API/issues?state=all&labels=feature_${feature_id}")

    validate_response "$response" "checking existing issues" || return 1
    
    local exists=$(echo "$response" | jq -r '. | length')

    if [ "$exists" -eq 0 ]; then
        echo "Creating issue: [$module] $feature"
        local response=$(curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" "$GITHUB_API/issues" \
            -d "{
                \"title\": \"[$module] $feature\",
                \"body\": \"Implementation of $feature feature in $module module\\n\\nPriority: $priority\",
                \"labels\": [\"$module\", \"$priority\"]
            }")
        
        validate_response "$response" "creating issue" || return 1

        # Extract issue number from response
        local issue_number=$(echo "$response" | jq -r '.number')
        
        if [ -n "$issue_number" ] && [ "$issue_number" != "null" ]; then
            # Update README with issue link
            update_readme_with_issue "$module" "$feature" "$issue_number" || return 1
        else
            echo "Error: Failed to get issue number from response"
            return 1
        fi
    else
        echo "Issue already exists for feature: $feature"
    fi
}

# Function to update README with issue link
update_readme_with_issue() {
    local module=$1
    local feature=$2
    local issue_number=$3
    local readme_file="shared-modules/$module/README.md"
    local main_readme="README.md"
    local temp_file="${readme_file}.tmp"
    local main_temp_file="${main_readme}.tmp"
    local issue_link="https://github.com/$GITHUB_REPOSITORY/issues/$issue_number"

    # Validate files exist
    if [ ! -f "$readme_file" ]; then
        echo "Error: Module README not found: $readme_file"
        return 1
    fi

    if [ ! -f "$main_readme" ]; then
        echo "Error: Main README not found: $main_readme"
        return 1
    fi

    # Update module README
    >"$temp_file"
    local found_feature=false
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*-[[:space:]]*\[.*\][[:space:]]*"$feature"[[:space:]]*#.*$ ]]; then
            found_feature=true
            echo "${line%#*} # issue: [#${issue_number}]($issue_link)" >> "$temp_file"
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$readme_file"

    if [ "$found_feature" = false ]; then
        echo "Error: Feature not found in module README: $feature"
        rm "$temp_file"
        return 1
    fi

    # Validate temp file is not empty
    if [ ! -s "$temp_file" ]; then
        echo "Error: Generated module README is empty"
        rm "$temp_file"
        return 1
    fi

    mv "$temp_file" "$readme_file"

    # Update main README
    >"$main_temp_file"
    found_feature=false
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*-[[:space:]]*\[.*\][[:space:]]*"$feature"[[:space:]]*#.*$ ]]; then
            found_feature=true
            echo "${line%#*} # issue: [#${issue_number}]($issue_link)" >> "$main_temp_file"
        else
            echo "$line" >> "$main_temp_file"
        fi
    done < "$main_readme"

    if [ "$found_feature" = false ]; then
        echo "Error: Feature not found in main README: $feature"
        rm "$main_temp_file"
        return 1
    fi

    # Validate temp file is not empty
    if [ ! -s "$main_temp_file" ]; then
        echo "Error: Generated main README is empty"
        rm "$main_temp_file"
        return 1
    fi

    mv "$main_temp_file" "$main_readme"
}

# Function to extract feature ID from line
get_feature_id() {
    local line=$1
    if [[ $line =~ "#"[[:space:]]*"id:"[[:space:]]*([[:alnum:]_]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

# Function to get all modules from README
get_all_modules() {
    local readme_file="README.md"
    local modules=()
    local in_modules_section=false

    while IFS= read -r line; do
        if [[ $line =~ ^"## Shared Modules"$ ]]; then
            in_modules_section=true
            continue
        fi

        if [[ $in_modules_section == true ]]; then
            if [[ $line =~ ^"##" ]]; then
                break
            fi

            if [[ $line =~ ^\|.*\|.*\|.*\| ]]; then
                if [[ $line =~ ^\|[[:space:]]*-+ ]]; then
                    continue
                fi

                local module_name=$(echo "$line" | sed -E 's/\|[[:space:]]*\[[[:space:]]*[xX ]?\][[:space:]]*\|[[:space:]]*([^|]+).*/\1/' | sed -E 's/[[:space:]]*$//')
                module_name=$(echo "$module_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]*&[[:space:]]*//')
                modules+=("$module_name")
            fi
        fi
    done <"$readme_file"

    echo "${modules[@]}"
}

# Function to scan features and create issues
scan_features() {
    local module=$1
    local readme_file="shared-modules/$module/README.md"

    if [ ! -f "$readme_file" ]; then
        echo "Error: Module README not found: $readme_file"
        return 1
    fi

    local current_priority=""
    echo "Scanning features for module: $module"

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
                continue
            fi

            create_github_issue "$module" "$feature" "$current_priority" || return 1
        fi
    done <"$readme_file"
}

# Main execution
if [[ $# -eq 4 ]]; then
    # Direct call with parameters
    create_github_issue "$1" "$2" "$3" "$4"
else
    # Scan mode
    echo "Starting issue creation process..."

    # Get all modules from README
    read -ra modules <<<"$(get_all_modules)"

    # Scan all modules
    for module in "${modules[@]}"; do
        scan_features "$module" || exit 1
    done

    echo "Issue creation process completed"
fi
