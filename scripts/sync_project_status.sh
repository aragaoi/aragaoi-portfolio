#!/bin/bash

# Updates project progress bars in main README based on feature completion
# - Calculates completion percentage for each project
# - Updates progress bars in project overview table
# - Called by GitHub Actions after feature status changes
# - Uses module completion status to calculate project progress

set -e # Exit on error

# Function to count features and calculate progress
calculate_progress() {
    local module=$1
    local readme_file="shared-modules/$module/README.md"

    # Count total features and completed ones
    local total=$(grep -c '- \[.\]' "$readme_file")
    local completed=$(grep -c '- \[x\]' "$readme_file")

    # Calculate percentage
    if [ $total -eq 0 ]; then
        echo 0
    else
        echo $(((completed * 100) / total))
    fi
}

# Function to generate progress bar
generate_progress_bar() {
    local percentage=$1
    local filled=$((percentage / 10))
    local empty=$((10 - filled))

    printf "["
    for ((i = 0; i < filled; i++)); do printf "█"; done
    for ((i = 0; i < empty; i++)); do printf "▱"; done
    printf "] %d%%" "$percentage"
}

# Function to extract module dependencies from README
get_project_modules() {
    local project=$1
    local readme_file="README.md"
    local modules=()
    local in_modules_section=false
    local found_modules=""

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

                # Extract module name from markdown link
                local module_name=$(echo "$line" | sed -E 's/\|[[:space:]]*\[[[:space:]]*[xX ]?\][[:space:]]*\|[[:space:]]*\[(.*?)\]\(.*\)/\1/' | sed -E 's/[[:space:]]*$//')

                # Extract project links and check if our project is in the list
                if echo "$line" | grep -q "\[$project\]"; then
                    module_name=$(echo "$module_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]*&[[:space:]]*//')
                    modules+=("$module_name")
                fi
            fi
        fi
    done <"$readme_file"

    echo "${modules[@]}"
}

# Calculate project progress based on its modules
calculate_project_progress() {
    local project=$1
    local total_progress=0
    local module_count=0

    # Read module dependencies from README
    read -ra modules <<<"$(get_project_modules "$project")"

    # Calculate average progress of dependent modules
    for module in "${modules[@]}"; do
        total_progress=$((total_progress + $(calculate_progress "$module")))
        module_count=$((module_count + 1))
    done

    if [ $module_count -eq 0 ]; then
        echo 0
    else
        echo $((total_progress / module_count))
    fi
}

# Update project progress in README
update_project_progress() {
    local project=$1
    local progress=$(calculate_project_progress "$project")
    local progress_bar=$(generate_progress_bar "$progress")

    # Update the project status in README.md
    sed -i "" "s/|\s*\[.*\]\s*[0-9]*%\s*| $project/| $progress_bar | $project/" README.md
}

# Main execution
main() {
    # Only proceed if the commit is not from the automation
    if [[ $(git log -1 --pretty=format:'%an') == "GitHub Action" ]]; then
        echo "Changes made by automation, skipping project sync"
        exit 0
    fi

    echo "Starting project sync process..."

    # Get all projects from README
    projects=($(grep -A 100 "^## Projects Overview$" README.md | grep -B 100 "^##" | grep "^\|.*\|.*\|.*\|.*\|$" | grep -v "^|[[:space:]]*-" | grep -v "Status.*Project.*Description.*Repository" | sed -E 's/\|[[:space:]]*\[.*\][[:space:]]*[0-9]*%[[:space:]]*\|[[:space:]]*([^|]+).*/\1/' | sed -E 's/[[:space:]]*$//' | grep -v "^$"))

    # Update all projects
    for project in "${projects[@]}"; do
        update_project_progress "$project"
    done

    echo "Project sync process completed"
}

main
