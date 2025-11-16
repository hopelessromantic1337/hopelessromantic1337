#!/usr/bin/env bats

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    source "$(dirname "$BATS_TEST_FILENAME")/../functions.sh"
}

@test "check_password_strength: too short" {
    run check_password_strength "Ab1@"
    assert_failure
    assert_output "Password must be at least 8 characters long."
}

@test "check_password_strength: no uppercase" {
    run check_password_strength "abc123@def"
    assert_failure
    assert_output "Password must contain at least one uppercase letter."
}

@test "check_password_strength: no lowercase" {
    run check_password_strength "ABC123@DEF"
    assert_failure
    assert_output "Password must contain at least one lowercase letter."
}

@test "check_password_strength: no digit" {
    run check_password_strength "Abc@defgh"
    assert_failure
    assert_output "Password must contain at least one digit."
}

@test "check_password_strength: no special character" {
    run check_password_strength "Abc123def"
    assert_failure
    assert_output "Password must contain at least one special character."
}

@test "check_password_strength: weak entropy" {
    run check_password_strength "Ab1@abcd"
    assert_failure
    assert_output --partial "Password entropy too low"
}

@test "check_password_strength: strong password" {
    run check_password_strength "Ab1@1234567890"
    assert_success
    assert_output --partial "Password entropy: 92 bits (strong)."
}

@test "check_password_strength: empty password" {
    run check_password_strength ""
    assert_failure
    assert_output "Password must be at least 8 characters long."
}

@test "check_password_strength: invalid charset" {
    run check_password_strength "%%%%%%%%"
    assert_failure
    assert_output "Password must contain at least one uppercase letter."
}
