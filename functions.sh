#!/bin/bash

# Function to check password strength
check_password_strength() {
    local pwd="$1"
    if [[ ${#pwd} -lt 8 ]]; then
        echo "Password must be at least 8 characters long."
        return 1
    fi
    if ! [[ "$pwd" =~ [A-Z] ]]; then
        echo "Password must contain at least one uppercase letter."
        return 1
    fi
    if ! [[ "$pwd" =~ [a-z] ]]; then
        echo "Password must contain at least one lowercase letter."
        return 1
    fi
    if ! [[ "$pwd" =~ [0-9] ]]; then
        echo "Password must contain at least one digit."
        return 1
    fi
    if ! [[ "$pwd" =~ [^a-zA-Z0-9] ]]; then
        echo "Password must contain at least one special character."
        return 1
    fi

    # Entropy calculation
    local length=${#pwd}
    local charset=0
    [[ "$pwd" =~ [a-z] ]] && charset=$((charset + 26))
    [[ "$pwd" =~ [A-Z] ]] && charset=$((charset + 26))
    [[ "$pwd" =~ [0-9] ]] && charset=$((charset + 10))
    [[ "$pwd" =~ [^a-zA-Z0-9] ]] && charset=$((charset + 33))
    if [[ $charset -eq 0 ]]; then
        echo "Invalid password."
        return 1
    fi
    local entropy
    entropy=$(echo "$length * l($charset)/l(2)" | bc -l | awk '{printf "%.0f\n", $0}') || { echo "Failed to calculate entropy"; return 1; }
    if [[ $entropy -lt 60 ]]; then
        echo "Password entropy too low: $entropy bits (need at least 60)."
        return 1
    fi
    echo "Password entropy: $entropy bits (strong)."
    return 0
}
