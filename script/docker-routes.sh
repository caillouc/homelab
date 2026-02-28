#!/bin/bash

# Define the target route
TARGET_ROUTE="10.8.0.0/24 via 10.10.0.10"

# Check if the route already exists
if ! ip route | grep -q "$TARGET_ROUTE"; then
    echo "Route not found, adding it..."
    # Add the route if it doesn't exist
    ip route add 10.8.0.0/24 via 10.10.0.10
else
    echo "Route already exists."
fi

