# n8n v2.0 Instance Migration Guide

This guide documents the required changes to migrate The Health Suite n8n instances to v2.0 compatibility.

## Overview

n8n 2.0 introduces breaking changes that affect instance configuration, particularly around security defaults and Docker image structure. This document tracks the changes needed for both local test and production environments.

## Migration Status

- [x] Feature branch created: `chore/n8n-v2-instance-compatibility`
- [ ] Local test environment updated
- [ ] Production environment configuration updated
- [ ] OAuth callback authentication tested
- [ ] Task runners configuration verified
- [ ] Documentation updated
- [ ] Changes tested in local environment
- [ ] Production deployment plan created

## Required Changes

### 1. OAuth Callback URL Authentication (SECURITY ENHANCEMENT)

**Breaking Change:** OAuth callbacks now enforce n8n user authentication by default for improved security.

**Reference:** https://docs.n8n.io/2-0-breaking-changes/#require-authentication-on-oauth-callback-urls-by-default

**Security Impact:**
- Default value for `N8N_SKIP_AUTH_ON_OAUTH_CALLBACK` changes from `true` (insecure) to `false` (secure)
- **`false` = SECURE**: Requires n8n user authentication on OAuth callbacks
- **`true` = INSECURE**: Skips authentication (legacy v1.x behavior)
- This is **critical for healthcare data security** - OAuth callbacks should only be accessible to authenticated users

**Why This Matters for Healthcare:**
- Prevents unauthorized access to OAuth callback endpoints
- Ensures only authenticated n8n users can complete OAuth flows
- Aligns with GDPR and healthcare data protection requirements
- Reduces attack surface for potential OAuth-based exploits

**Action Required:**
1. ✅ **Already configured**: Set `N8N_SKIP_AUTH_ON_OAUTH_CALLBACK=false` in both environments
2. **Test OAuth flows** with authentication enabled to ensure smooth operation
3. **Verify** all team members have proper n8n user accounts
4. **Document** any issues during OAuth authentication flows

**Affected Files:**
- `../n8n-local-test/docker-compose.yml` (local test environment)
- `docker-compose.production.yml` (production environment)

**Testing Checklist:**
- [ ] Local: OAuth credentials can be created
- [ ] Local: OAuth authentication flows complete successfully
- [ ] Production: OAuth credentials tested
- [ ] Production: OAuth authentication flows verified

### 2. Task Runners Docker Image Separation

**Breaking Change:** Task runners are no longer included in the `n8nio/n8n` Docker image and must use the separate `n8nio/runners` image.

**Reference:** https://docs.n8n.io/2-0-breaking-changes/#remove-task-runner-from-n8nion8n-docker-image

**Impact:**
- Current setup has `N8N_RUNNERS_ENABLED=true` in both environments
- v2.0 requires separate `n8nio/runners` Docker container when using external mode
- Code node executions will run on task runners for better security and isolation

**Current Configuration:**
Both `docker-compose.yml` files currently have:
```yaml
environment:
  - N8N_RUNNERS_ENABLED=true
```

**Action Required:**

#### Option 1: Use Internal Task Runners (Simpler - Recommended for Local)
Keep current configuration with `N8N_RUNNERS_ENABLED=true`. Task runners will run inside the main n8n container.

**Pros:**
- Simpler setup
- No additional containers needed
- Suitable for local development

**Cons:**
- Less isolation
- Less secure for production

#### Option 2: Use External Task Runners (More Secure - Recommended for Production)
Add separate `n8nio/runners` service to docker-compose.

**Pros:**
- Better security and isolation
- Recommended for production
- More scalable

**Cons:**
- More complex setup
- Requires additional container

**Implementation Plan:**
1. **Local Environment** (`n8n-local-test`): Keep internal task runners for simplicity
2. **Production Environment**: Evaluate need for external task runners based on security requirements

**Testing Checklist:**
- [ ] Local: Code node executions work
- [ ] Local: Python Code node executions work (if used)
- [ ] Production: Task runner configuration tested
- [ ] Production: Code node performance verified

## OAuth Integrations Inventory

**Current OAuth-based integrations in use:**
- [ ] Google Services (Sheets, Drive, Calendar, etc.)
- [ ] Microsoft Services
- [ ] Other: _____________

**Note:** Document all OAuth integrations here for testing coverage.

## Environment Files to Update

### Local Test Environment
**File:** `/Users/mikehatcher/Websites/the-health-suite/n8n-local-test/docker-compose.yml`
- ✅ Added `N8N_SKIP_AUTH_ON_OAUTH_CALLBACK=false`

### Production Environment
**File:** `/Users/mikehatcher/Websites/the-health-suite/n8n-nodes-semble/docker-compose.production.yml`
- ✅ Added `N8N_SKIP_AUTH_ON_OAUTH_CALLBACK=false`
- Evaluate external task runners setup

## Related Documentation

- [n8n 2.0 Breaking Changes](https://docs.n8n.io/2-0-breaking-changes/)
- [Task Runners Configuration](https://docs.n8n.io/hosting/configuration/task-runners/)
- [OAuth Callback Security](https://docs.n8n.io/hosting/configuration/environment-variables/security/#n8n_skip_auth_on_oauth_callback)

## Rollback Plan

**⚠️ WARNING:** The rollback approach below reduces security and is NOT recommended for production healthcare data.

If critical issues occur during migration that cannot be resolved:

1. **Temporary OAuth bypass** (only if OAuth flows fail and blocking critical operations)
   ```yaml
   # INSECURE: Only use temporarily for troubleshooting
   # Remove as soon as OAuth issues are resolved
   - N8N_SKIP_AUTH_ON_OAUTH_CALLBACK=true
   ```
   **Document:** Why this was needed, timeline for fix, and create issue to resolve

2. **Pin to v1.x version** (if multiple blocking issues)
   ```yaml
   # In docker-compose.yml
   image: n8nio/n8n:1.71.2  # Last stable v1.x version
   ```
   **Note:** Schedule upgrade as soon as issues are resolved - v1.x has security gaps

3. **Restore from backup** if data corruption occurs

## Timeline

- **Planning & Documentation:** January 12, 2026
- **Local Testing:** _TBD_
- **Production Deployment:** _TBD after successful testing_

## Notes

- All changes should be tested in local environment before production
- Monitor n8n release notes for additional v2.0 guidance
- Consider upgrading to v2.0 shortly after release for security improvements
