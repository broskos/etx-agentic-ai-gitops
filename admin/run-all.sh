#!/bin/bash

# Script to run all admin scripts in order
# Usage: ./run-all.sh <number_of_users>

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if number of users is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <number_of_users>"
    echo "Example: $0 7"
    exit 1
fi

NUM_USERS=$1

# Validate that NUM_USERS is a positive integer
if ! [[ "$NUM_USERS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: Number of users must be a positive integer"
    exit 1
fi

# Validate if user is logged in as admin
if ! oc whoami &> /dev/null; then
    echo "Error: Not logged in to the cluster. Please run 'oc login' first."
    exit 1
fi

CURRENT_USER=$(oc whoami)
if [ "${CURRENT_USER}" != "admin" ]; then
    echo "Error: Must be logged in as 'admin'. Current user: ${CURRENT_USER}"
    exit 1
fi

echo "✓ Logged in as: ${CURRENT_USER}"
echo

echo "================================================================"
echo "Running all admin scripts for ${NUM_USERS} users"
echo "================================================================"
echo

# Array of scripts to run in order
SCRIPTS=(
    "01-create-mcp-github.sh"
    "02-update-llama-stack-config.sh"
    "03-create-ai-agent-pipelinerun.sh"
    "04-create-ai-agent-application.sh"
    "05-create-java-app-build.sh"
)

# Run each script in order
for script in "${SCRIPTS[@]}"; do
    SCRIPT_PATH="${SCRIPT_DIR}/${script}"

    if [ ! -f "${SCRIPT_PATH}" ]; then
        echo "Error: Script ${script} not found!"
        exit 1
    fi

    echo "================================================================"
    echo "Running: ${script}"
    echo "================================================================"
    echo

    # Run the script with the number of users parameter
    "${SCRIPT_PATH}" "${NUM_USERS}"

    # Check exit status
    if [ $? -ne 0 ]; then
        echo
        echo "✗ Script ${script} failed!"
        echo
        echo "Aborting execution."
        exit 1
    else
        echo
        echo "✓ Script ${script} completed successfully"
        echo
    fi
done

echo "================================================================"
echo "All scripts completed successfully!"
echo "================================================================"

echo "================================================================"
echo "Starting verification process"
echo "================================================================"
echo

echo "Checking if all ai-agent deployments have been created..."
echo "Expected: ${NUM_USERS} deployment(s)"
echo

TIMEOUT=300  # 5 minutes in seconds
INTERVAL=10  # Check every 10 seconds
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    DEPLOYMENT_COUNT=$(oc get deploy -l app.kubernetes.io/instance=ai-agent -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    echo "Current deployment count: ${DEPLOYMENT_COUNT}/${NUM_USERS}"
    
    if [ "${DEPLOYMENT_COUNT}" -eq "${NUM_USERS}" ]; then
        echo "✓ All ${NUM_USERS} ai-agent deployment(s) have been created!"
        echo
        break
    fi
    
    if [ $ELAPSED -lt $TIMEOUT ]; then
        echo "Waiting for deployments to be created... (${ELAPSED}s/${TIMEOUT}s)"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    fi
done

FINAL_COUNT=$(oc get deploy -l app.kubernetes.io/instance=ai-agent -A --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "${FINAL_COUNT}" -ne "${NUM_USERS}" ]; then
    echo
    echo "✗ Timeout: Expected ${NUM_USERS} deployment(s), but found ${FINAL_COUNT}"
    echo "Aborting verification."
    exit 1
fi

echo "Waiting for ai-agent deployments to become available in all namespaces..."
echo "This may take up to 20 minutes..."
echo

if oc wait --for=condition=Available deploy -l app.kubernetes.io/instance=ai-agent -A --timeout=20m; then
    echo
    echo "✓ All ai-agent deployments are available!"
    echo
else
    echo
    echo "✗ Verification failed: Some ai-agent deployments are not available"
    echo
    echo "Checking deployment status in user namespaces..."
    echo
    
    # Check each user namespace individually for better error reporting
    FAILED_NAMESPACES=0
    for i in $(seq 1 ${NUM_USERS}); do
        NAMESPACE="user${i}-ai-agent"
        if oc get namespace "${NAMESPACE}" &>/dev/null; then
            if oc wait --for=condition=Available deploy -l app.kubernetes.io/instance=ai-agent -n "${NAMESPACE}" --timeout=30s &>/dev/null; then
                echo "  ✓ ${NAMESPACE}: ai-agent deployment is available"
            else
                echo "  ✗ ${NAMESPACE}: ai-agent deployment is not available"
                FAILED_NAMESPACES=$((FAILED_NAMESPACES + 1))
            fi
        else
            echo "  ⚠ ${NAMESPACE}: namespace does not exist"
        fi
    done
    
    if [ $FAILED_NAMESPACES -gt 0 ]; then
        echo
        echo "Error: ${FAILED_NAMESPACES} namespace(s) have unavailable ai-agent deployments"
        exit 1
    fi
fi

echo "================================================================"
echo "Verification completed successfully!"
echo "================================================================"
echo

exit 0
