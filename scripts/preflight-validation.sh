#!/usr/bin/env bash
#
# Skyr 1.0 Preflight Validation Script
#
# Runs automated checks that do not require physical devices or TestFlight.
# Use this before device acceptance testing to catch configuration issues early.
#
# Usage: ./scripts/preflight-validation.sh [--skip-tests] [--skip-build]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SKIP_TESTS=false
SKIP_BUILD=false
FAILED=0
PASSED=0

for arg in "$@"; do
    case $arg in
        --skip-tests) SKIP_TESTS=true ;;
        --skip-build) SKIP_BUILD=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-tests] [--skip-build]"
            echo "  --skip-tests  Skip Swift package tests"
            echo "  --skip-build  Skip Xcode build validation"
            exit 0
            ;;
    esac
done

section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    FAILED=$((FAILED + 1))
}

warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

info() {
    echo -e "  $1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Version Alignment Check
# ─────────────────────────────────────────────────────────────────────────────

section "Version Alignment"

EXPECTED_MARKETING="1.0"
EXPECTED_BUILD="202609142150"

check_version() {
    local target=$1
    local file="$PROJECT_ROOT/project.yml"
    
    # Extract versions for the target from project.yml
    local marketing=$(grep -A 100 "^  $target:" "$file" | grep "MARKETING_VERSION:" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')
    local build=$(grep -A 100 "^  $target:" "$file" | grep "CURRENT_PROJECT_VERSION:" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')
    
    if [[ "$marketing" == "$EXPECTED_MARKETING" && "$build" == "$EXPECTED_BUILD" ]]; then
        pass "$target: $marketing ($build)"
    else
        fail "$target: expected $EXPECTED_MARKETING ($EXPECTED_BUILD), got $marketing ($build)"
    fi
}

check_version "Skyr"
check_version "SkyrWidgets"
check_version "SkyrWatch"
check_version "SkyrMac"
check_version "SkyrTV"

# ─────────────────────────────────────────────────────────────────────────────
# Privacy Manifest Check
# ─────────────────────────────────────────────────────────────────────────────

section "Privacy Manifests"

check_privacy_manifest() {
    local path="$PROJECT_ROOT/$1/PrivacyInfo.xcprivacy"
    local target=$2
    
    if [[ -f "$path" ]]; then
        # Check for required keys
        if grep -q "NSPrivacyTracking" "$path"; then
            pass "$target privacy manifest exists with tracking declaration"
        else
            fail "$target privacy manifest missing NSPrivacyTracking"
        fi
    else
        fail "$target privacy manifest not found at $1/PrivacyInfo.xcprivacy"
    fi
}

check_privacy_manifest "Skyr" "iOS"
check_privacy_manifest "SkyrWidgets" "Widgets"
check_privacy_manifest "SkyrWatch" "Watch"
check_privacy_manifest "SkyrMac" "Mac"
check_privacy_manifest "SkyrTV" "TV"

# ─────────────────────────────────────────────────────────────────────────────
# Export Compliance Check
# ─────────────────────────────────────────────────────────────────────────────

section "Export Compliance (ITSAppUsesNonExemptEncryption)"

check_export_compliance() {
    local file="$PROJECT_ROOT/project.yml"
    local target=$1
    local is_embedded=${2:-false}
    
    # Search in the target's section for the encryption declaration
    if grep -A 100 "^  $target:" "$file" | grep -q "ITSAppUsesNonExemptEncryption: false"; then
        pass "$target declares non-exempt encryption"
    else
        # Also check the Info.plist directly if it exists
        local plist_path=""
        case $target in
            Skyr) plist_path="$PROJECT_ROOT/Skyr/Info.plist" ;;
            SkyrWatch) plist_path="$PROJECT_ROOT/SkyrWatch/Info.plist" ;;
            SkyrMac) plist_path="$PROJECT_ROOT/SkyrMac/Info.plist" ;;
            SkyrTV) plist_path="$PROJECT_ROOT/SkyrTV/Info.plist" ;;
        esac
        
        if [[ -n "$plist_path" && -f "$plist_path" ]] && grep -q "ITSAppUsesNonExemptEncryption" "$plist_path"; then
            pass "$target declares non-exempt encryption (in Info.plist)"
        elif [[ "$is_embedded" == "true" ]]; then
            warn "$target embedded extension inherits from parent app"
        else
            fail "$target missing or incorrect ITSAppUsesNonExemptEncryption"
        fi
    fi
}

check_export_compliance "Skyr"
check_export_compliance "SkyrWatch" "true"  # Watch is embedded in iOS app
check_export_compliance "SkyrMac"
check_export_compliance "SkyrTV"
# Widgets extension inherits from main app; check not required

# ─────────────────────────────────────────────────────────────────────────────
# Entitlements Check
# ─────────────────────────────────────────────────────────────────────────────

section "Entitlements Configuration"

check_entitlement() {
    local file="$PROJECT_ROOT/$1"
    local entitlement=$2
    local description=$3
    
    if [[ -f "$file" ]]; then
        if grep -q "$entitlement" "$file" 2>/dev/null; then
            pass "$description"
        else
            fail "$description - entitlement not found"
        fi
    else
        # Check in project.yml for inline entitlements
        if grep -q "$entitlement" "$PROJECT_ROOT/project.yml"; then
            pass "$description (inline)"
        else
            fail "$description - file not found and not inline"
        fi
    fi
}

# iOS entitlements
check_entitlement "project.yml" "com.apple.security.application-groups" "iOS: App Groups"
check_entitlement "project.yml" "com.apple.developer.icloud-container-identifiers" "iOS: CloudKit"
check_entitlement "project.yml" "com.apple.developer.carplay-audio" "iOS: CarPlay Audio"
check_entitlement "project.yml" "aps-environment" "iOS: Push Notifications"

# Mac entitlements
check_entitlement "project.yml" "com.apple.security.app-sandbox" "Mac: App Sandbox"
check_entitlement "project.yml" "com.apple.security.network.client" "Mac: Network Client"

# ─────────────────────────────────────────────────────────────────────────────
# Required Files Check
# ─────────────────────────────────────────────────────────────────────────────

section "Required Files"

check_file() {
    local path="$PROJECT_ROOT/$1"
    local description=$2
    
    if [[ -f "$path" ]]; then
        pass "$description"
    else
        fail "$description not found at $1"
    fi
}

check_file "docs/PRIVACY-POLICY.md" "Privacy policy draft"
check_file "docs/PRIVACY-RELEASE-CHECK.md" "Privacy release checklist"
check_file "docs/RELEASE-AUDIT-2026-09-14.md" "Release audit"
check_file "docs/TESTFLIGHT-ACCEPTANCE-MATRIX.md" "Acceptance matrix"

# ─────────────────────────────────────────────────────────────────────────────
# Swift Package Tests
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$SKIP_TESTS" == "false" ]]; then
    section "Swift Package Tests"
    
    cd "$PROJECT_ROOT/Packages/SkyrCore"
    
    if swift test 2>&1 | tee /tmp/swift-test-output.txt | tail -20; then
        TEST_RESULT=$(grep -E "Test Suite.*passed|tests passed" /tmp/swift-test-output.txt | tail -1 || echo "")
        if [[ -n "$TEST_RESULT" ]]; then
            pass "Package tests: $TEST_RESULT"
        else
            # Check for any failures in output
            if grep -q "failed" /tmp/swift-test-output.txt; then
                fail "Package tests had failures"
            else
                pass "Package tests completed"
            fi
        fi
    else
        fail "Package tests failed to run"
    fi
    
    cd "$PROJECT_ROOT"
else
    section "Swift Package Tests (SKIPPED)"
    warn "Tests skipped via --skip-tests flag"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Xcode Build Validation (if available)
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$SKIP_BUILD" == "false" ]]; then
    section "Xcode Build Validation"
    
    if command -v xcodebuild &> /dev/null; then
        info "Checking project generation..."
        
        if [[ -d "$PROJECT_ROOT/Skyr.xcodeproj" ]]; then
            pass "Xcode project exists"
            
            # List available schemes
            SCHEMES=$(xcodebuild -project "$PROJECT_ROOT/Skyr.xcodeproj" -list 2>/dev/null | grep -A 100 "Schemes:" | tail -n +2 | head -10 | tr -d ' ' || echo "")
            if [[ -n "$SCHEMES" ]]; then
                pass "Project schemes available: $(echo $SCHEMES | tr '\n' ' ')"
            else
                warn "Could not list project schemes"
            fi
        else
            warn "Xcode project not found - run xcodegen if needed"
        fi
    else
        warn "xcodebuild not available - skipping build validation"
    fi
else
    section "Xcode Build Validation (SKIPPED)"
    warn "Build validation skipped via --skip-build flag"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

section "Summary"

TOTAL=$((PASSED + FAILED))

echo ""
echo -e "  ${GREEN}Passed${NC}: $PASSED"
echo -e "  ${RED}Failed${NC}: $FAILED"
echo -e "  Total:  $TOTAL"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  All preflight checks passed!${NC}"
    echo -e "${GREEN}  Proceed to device acceptance testing.${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    exit 0
else
    echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}  $FAILED preflight check(s) failed.${NC}"
    echo -e "${RED}  Fix issues before device acceptance testing.${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
    exit 1
fi
