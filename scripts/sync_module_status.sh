#!/bin/bash

# Synchronizes module feature status between main README and module READMEs
# - Ensures feature completion status is consistent across all READMEs
# - Updates module status in main README overview table
# - Called by GitHub Actions after feature status changes
# - Maintains single source of truth for feature status

set -e # Exit on error

# Function to extract feature name from module README
get_feature_name() {
    local line=$1
    echo "$line" | sed -E 's/- \[.\] (.*)/\1/'
}

# Function to update feature status in module README
update_module_feature() {
    local module=$1
    local feature=$2
    local status=$3
    local readme_file="shared-modules/$module/README.md"
    local temp_file="$readme_file.tmp"

    # Create temp file
    >"$temp_file"

    while IFS= read -r line; do
        if [[ $(get_feature_name "$line") == "$feature" ]]; then
            if [ "$status" = "complete" ]; then
                echo "${line/\[ \]/\[x\]}" >>"$temp_file"
            else
                echo "${line/\[x\]/\[ \]}" >>"$temp_file"
            fi
        else
            echo "$line" >>"$temp_file"
        fi
    done <"$readme_file"

    mv "$temp_file" "$readme_file"
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

# Function to sync module README with main README status
sync_module_status() {
    local module=$1
    local main_readme="README.md"
    local module_section_start=$(grep -n "### \[$module\]" "$main_readme" | cut -d: -f1)

    if [ -z "$module_section_start" ]; then
        echo "Module section not found in main README: $module"
        return
    fi

    # Extract features and their status from main README
    while IFS= read -r line; do
        if [[ $line =~ ^"- \["* ]]; then
            local feature=$(get_feature_name "$line")
            if [[ $line =~ "\[x\]" ]]; then
                update_module_feature "$module" "$feature" "complete"
            else
                update_module_feature "$module" "$feature" "incomplete"
            fi
        fi
    done < <(tail -n +$module_section_start "$main_readme" | grep "^- \[")
}

# Main execution
main() {
    # Only proceed if the commit is not from the automation
    if [[ $(git log -1 --pretty=format:'%an') == "GitHub Action" ]]; then
        echo "Changes made by automation, skipping module sync"
        exit 0
    fi

    echo "Starting module sync process..."

    # Get all modules from README
    read -ra modules <<<"$(get_all_modules)"

    # Sync all modules
    for module in "${modules[@]}"; do
        echo "Syncing module: $module"
        sync_module_status "$module"
    done

    echo "Module sync process completed"
}

main
