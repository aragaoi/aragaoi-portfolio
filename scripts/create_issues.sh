#!/bin/bash

# Creates GitHub issues for features defined in module README files
# - Creates an issue for each uncompleted feature
# - Updates README files with issue links
# - Supports both direct feature creation and bulk scanning mode
# - Requires GITHUB_TOKEN and GITHUB_REPOSITORY in .env file

set -e  # Exit on error

# Load environment variables from .env file
if [ -f "$(dirname "$0")/../.env" ]; then
    echo "Loading environment variables from: $(dirname "$0")/../.env"
    set -a
    source "$(dirname "$0")/../.env"
    set +a
    
    # Debug output
    echo "GITHUB_REPOSITORY: $GITHUB_REPOSITORY"
    echo "GITHUB_PROJECT_NUMBER: $GITHUB_PROJECT_NUMBER"
    echo "GITHUB_TOKEN length: ${#GITHUB_TOKEN}"
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

if [ -z "$GITHUB_PROJECT_NUMBER" ]; then
    echo "Error: GITHUB_PROJECT_NUMBER environment variable is not set"
    exit 1
fi

# GitHub configuration
GITHUB_API="https://api.github.com/repos/$GITHUB_REPOSITORY"

# Function to validate API response
validate_response() {
    local response=$1
    local action=$2

    if [ -z "$response" ]; then
        echo "Error: Empty response from GitHub API during $action"
        return 1
    fi

    # Check if response is an error message
    if echo "$response" | jq -e 'if type=="object" then .message else null end' >/dev/null 2>&1; then
        local error_msg=$(echo "$response" | jq -r '.message')
        local error_doc=$(echo "$response" | jq -r '.documentation_url // ""')
        echo "Error during $action: $error_msg"
        if [ ! -z "$error_doc" ]; then
            echo "Documentation: $error_doc"
        fi
        return 1
    fi

    return 0
}

# Function to add issue to project
add_issue_to_project() {
    local issue_number=$1
    
    # Get issue node ID using GraphQL
    local issue_query='{
        "query": "query { repository(owner: \"'"${GITHUB_REPOSITORY%/*}"'\", name: \"'"${GITHUB_REPOSITORY#*/}"'\") { issue(number: '"$issue_number"') { id } } }"
    }'
    
    local issue_response=$(curl -s -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v4+json" \
        -H "Content-Type: application/json" \
        "https://api.github.com/graphql" \
        -d "$issue_query")
    
    validate_response "$issue_response" "getting issue ID" || return 1
    
    local issue_id=$(echo "$issue_response" | jq -r '.data.repository.issue.id')
    
    if [ -z "$issue_id" ] || [ "$issue_id" = "null" ]; then
        echo "Error: Issue number $issue_number not found"
        return 1
    fi
    
    # Get project ID using GraphQL
    local project_query='{
        "query": "query { viewer { projectV2(number: '"$GITHUB_PROJECT_NUMBER"') { id } } }"
    }'
    
    local project_response=$(curl -s -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v4+json" \
        -H "Content-Type: application/json" \
        "https://api.github.com/graphql" \
        -d "$project_query")
    
    validate_response "$project_response" "getting project ID" || return 1
    
    local project_id=$(echo "$project_response" | jq -r '.data.viewer.projectV2.id')
    
    if [ -z "$project_id" ] || [ "$project_id" = "null" ]; then
        echo "Error: Project number $GITHUB_PROJECT_NUMBER not found"
        return 1
    fi
    
    # Add issue to project using GraphQL
    local add_query='{
        "query": "mutation { addProjectV2ItemById(input: { projectId: \"'"$project_id"'\", contentId: \"'"$issue_id"'\" }) { item { id } } }"
    }'
    
    local add_response=$(curl -s -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v4+json" \
        -H "Content-Type: application/json" \
        "https://api.github.com/graphql" \
        -d "$add_query")
    
    validate_response "$add_response" "adding issue to project" || return 1
    echo "✓ Issue added to project board"
}

# Function to normalize feature name for comparison
normalize_feature_name() {
    local feature=$1
    # Remove extra spaces, convert to lowercase
    echo "$feature" | tr '[:upper:]' '[:lower:]' | xargs
}

# Function to create GitHub issue if it doesn't exist
create_github_issue() {
    local module=$1
    local feature=$2
    local priority=$3

    # Validate input
    if [ -z "$module" ] || [ -z "$feature" ] || [ -z "$priority" ]; then
        echo "Error: Missing required parameters for create_github_issue"
        echo "  module: $module"
        echo "  feature: $feature"
        echo "  priority: $priority"
        return 1
    fi

    # Create or get milestone for module
    echo "Checking for existing milestone for module: $module"
    local milestone_response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "$GITHUB_API/milestones?state=all")
    
    if ! validate_response "$milestone_response" "checking milestones"; then
        echo "Full milestone response: $milestone_response"
        return 1
    fi

    local milestone_number=$(echo "$milestone_response" | jq -r ".[] | select(.title == \"$module\") | .number")
    
    if [ -z "$milestone_number" ] || [ "$milestone_number" = "null" ]; then
        echo "Creating milestone for module: $module"
        local milestone_response=$(curl -s -X POST \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            -H "Content-Type: application/json" \
            "$GITHUB_API/milestones" \
            -d "{
                \"title\": \"$module\",
                \"description\": \"Features for the $module module\"
            }")
        
        if ! validate_response "$milestone_response" "creating milestone"; then
            echo "Full milestone creation response: $milestone_response"
            return 1
        fi
        milestone_number=$(echo "$milestone_response" | jq -r '.number')
    fi

    # Check if issue exists by feature ID label
    local search_query="[$module] $feature in:title repo:$GITHUB_REPOSITORY type:issue"
    local encoded_query=$(echo "$search_query" | jq -sRr @uri)
    echo "Searching for existing issues with query: $search_query"
    local response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/search/issues?q=$encoded_query")

    if ! validate_response "$response" "checking existing issues"; then
        echo "Full search response: $response"
        return 1
    fi
    
    local exists=$(echo "$response" | jq -r '.total_count')

    if [ "$exists" -eq 0 ]; then
        echo "Creating issue: [$module] $feature"
        local response=$(curl -s -X POST \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            -H "Content-Type: application/json" \
            "$GITHUB_API/issues" \
            -d "{
                \"title\": \"[$module] $feature\",
                \"body\": \"Implementation of $feature feature in $module module\\n\\nPriority: $priority\",
                \"milestone\": $milestone_number,
                \"labels\": [\"$priority\"]
            }")
        
        if ! validate_response "$response" "creating issue"; then
            echo "Full issue creation response: $response"
            return 1
        fi

        # Extract issue number from response
        local issue_number=$(echo "$response" | jq -r '.number')
        
        if [ -n "$issue_number" ] && [ "$issue_number" != "null" ]; then
            # Add issue to project board
            add_issue_to_project "$issue_number" || echo "Warning: Failed to add issue to project board"
            
            # Update README with issue link
            update_readme_with_issue "$module" "$feature" "$issue_number" || return 1
            echo "✓ Issue created successfully: https://github.com/$GITHUB_REPOSITORY/issues/$issue_number"
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
    local normalized_feature=$(normalize_feature_name "$feature")

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
        # Extract feature name from line, ignoring any trailing comments or whitespace
        local line_feature=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*\[.*\][[:space:]]*([^#]*)[[:space:]#]*.*/\1/')
        local normalized_line_feature=$(normalize_feature_name "$line_feature")
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[.*\] ]] && [[ "$normalized_line_feature" == "$normalized_feature" ]]; then
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
        # Extract feature name from line, ignoring any trailing comments or whitespace
        local line_feature=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*\[.*\][[:space:]]*([^#]*)[[:space:]#]*.*/\1/')
        local normalized_line_feature=$(normalize_feature_name "$line_feature")
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[.*\] ]] && [[ "$normalized_line_feature" == "$normalized_feature" ]]; then
            found_feature=true
            echo "${line%#*} # issue: [#${issue_number}]($issue_link)" >> "$main_temp_file"
        else
            echo "$line" >> "$main_temp_file"
        fi
    done < "$main_readme"

    if [ "$found_feature" = false ]; then
        echo "Warning: Feature not found in main README: $feature"
        rm "$main_temp_file"
        return 0  # Don't fail if feature is not in main README
    fi

    # Only update main README if feature was found
    if [ -s "$main_temp_file" ]; then
        mv "$main_temp_file" "$main_readme"
    else
        rm "$main_temp_file"
    fi
}

# Function to get all modules from README
get_all_modules() {
    local readme_file="README.md"
    local modules=()
    local in_modules_section=false
    local in_table=false
    local module_list=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]*Shared[[:space:]]*Modules[[:space:]]*Overview$ ]]; then
            in_modules_section=true
            continue
        fi

        if [[ "$in_modules_section" == true ]]; then
            if [[ "$line" =~ ^\|.*\|.*\|.*\| ]]; then
                if [[ "$line" =~ ^\|[[:space:]]*-+ ]]; then
                    in_table=true
                    continue
                fi
                if [[ "$in_table" == true ]]; then
                    # Extract module name from markdown link
                    local module_name=$(echo "$line" | sed -E 's/\|[[:space:]]*\[[^]]*\][[:space:]]*\|[[:space:]]*\[([^]]+)\].*/\1/')
                    module_name=$(echo "$module_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]*&[[:space:]]*//')
                    module_name=$(echo "$module_name" | sed -E 's/[[:space:]]+/-/g')
                    
                    if [ ! -z "$module_name" ]; then
                        # Convert specific module names
                        case "$module_name" in
                            "authentication-authorization"|"authenticationauthorization") module_name="auth" ;;
                            "reports-analytics"|"reportsanalytics") module_name="reports" ;;
                            "cost-estimation-optimization"|"cost-estimationoptimization") module_name="cost" ;;
                        esac
                        echo "Found module: $module_name" >&2
                        module_list="$module_list $module_name"
                    fi
                fi
            elif [[ "$in_table" == true ]]; then
                break
            fi
        fi
    done < "$readme_file"

    echo "$module_list"
}

# Function to scan features and create issues
scan_features() {
    local module=$1
    local readme_file="shared-modules/$module/README.md"
    local log_file="/tmp/issue_creation_${module}.log"

    if [ ! -f "$readme_file" ]; then
        echo "Error: Module README not found: $readme_file" >&2
        return 1
    fi

    local current_priority=""
    echo "Scanning features for module: $module" >&2

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
        elif [[ $line =~ ^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]* ]]; then
            # Extract feature name using basic string manipulation
            local feature="${line#*[[:space:]]\][[:space:]]}"
            feature="${feature%%#*}"
            feature="$(echo "$feature" | xargs)"  # Trim whitespace

            # Skip if feature already has an issue link
            if [[ $line =~ "#[[:space:]]*issue:[[:space:]]*\[#[0-9]+\]" ]]; then
                continue
            fi

            echo "Found unchecked feature: $feature (Priority: $current_priority)" >&2
            create_github_issue "$module" "$feature" "$current_priority" || return 1
        fi
    done <"$readme_file"
}

# Main execution block
main() {
    if [[ $# -eq 3 ]]; then
        # Direct call with parameters
        create_github_issue "$1" "$2" "$3"
    else
        # Scan mode
        echo "Starting issue creation process..."

        # Get all modules from README
        read -ra modules <<<"$(get_all_modules)"
        
        local total=${#modules[@]}
        local completed=0
        
        # Process each module sequentially
        for module in "${modules[@]}"; do
            echo "Processing module: $module [$((completed + 1))/$total]"
            if ! scan_features "$module"; then
                echo "Error processing module: $module"
                exit 1
            fi
            ((completed++))
        done
        
        echo "Issue creation process completed successfully"
    fi
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
