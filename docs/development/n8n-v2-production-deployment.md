# n8n v2.0 Production Deployment Guide

This guide covers deploying the n8n v2.0 instance with external task runners to production.

## Prerequisites

- [ ] Local testing completed successfully
- [ ] OAuth authentication tested and working
- [ ] Production environment accessible
- [ ] Docker and Docker Compose installed on production server
- [ ] SSL/TLS certificates configured for HTTPS
- [ ] Backup of current production instance completed

## Pre-Deployment Checklist

### 1. Generate Required Secrets

**Grant Token for Task Runners:**
```bash
# Generate a secure random token
openssl rand -base64 32

# Example output: xK9mP2vR8tY4wQ3nL6hJ5bN7cM1dF0gS8aT9uE4vW2x=
```

**Save this token** - you'll need it for the environment configuration.

### 2. Prepare Environment File

Create or update production `.env` file:

```bash
# n8n Version
N8N_PROD_VERSION=2.2.6

# Production API Key (existing)
N8N_PROD_API_KEY=<your-existing-api-key>

# Task Runner Grant Token (NEW - from step 1)
N8N_RUNNERS_GRANT_TOKEN=<token-from-openssl-command>

# Optional: Database credentials (if using PostgreSQL)
# POSTGRES_DB=n8n
# POSTGRES_USER=n8n
# POSTGRES_PASSWORD=<secure-password>
```

### 3. Review Docker Compose Configuration

**File:** `docker-compose.production.yml`

**Services Deployed:**
1. **n8n-production** - Main n8n application (port 5678)
2. **n8n-task-runner-js** - External task runner for Code nodes
3. **n8n-task-broker** - Task coordination service

**Key Configuration Points:**
- ✅ `N8N_SKIP_AUTH_ON_OAUTH_CALLBACK=false` (OAuth security)
- ✅ `N8N_RUNNERS_MODE=external` (task runner separation)
- ✅ Network isolation via `n8n-network`
- ✅ Health checks configured

## Deployment Steps

### Step 1: Backup Current Instance

```bash
# SSH to production server
ssh production-server

# Navigate to n8n directory
cd /path/to/n8n

# Stop current instance
docker compose down

# Backup data volume
docker run --rm \
  -v n8n_data:/data \
  -v $(pwd)/backups:/backup \
  alpine tar czf /backup/n8n-backup-$(date +%Y%m%d-%H%M%S).tar.gz /data

# Verify backup created
ls -lh backups/
```

### Step 2: Update Configuration Files

```bash
# Pull latest configuration from repository
git pull origin chore/n8n-v2-instance-compatibility

# Or manually update docker-compose.production.yml
# Ensure all v2.0 changes are present
```

### Step 3: Configure Environment Variables

```bash
# Edit .env file with generated tokens
nano .env

# Add/update:
# N8N_RUNNERS_GRANT_TOKEN=<your-generated-token>

# Verify environment variables
cat .env | grep -E "N8N_RUNNERS|N8N_SKIP_AUTH"
```

### Step 4: Deploy New Configuration

```bash
# Pull latest images
docker compose -f docker-compose.production.yml pull

# Start services
docker compose -f docker-compose.production.yml up -d

# Expected output:
# ✔ Network n8n-network              Created
# ✔ Container n8n-production         Started
# ✔ Container n8n-task-broker        Started
# ✔ Container n8n-task-runner-js     Started
```

### Step 5: Verify Deployment

```bash
# Check all containers are running
docker compose -f docker-compose.production.yml ps

# Expected status: All containers "Up" and healthy
# n8n-production        Up (healthy)
# n8n-task-broker       Up
# n8n-task-runner-js    Up

# Check logs for errors
docker compose -f docker-compose.production.yml logs -f --tail=50

# Look for successful startup messages:
# - "n8n ready on"
# - "Task Broker ready"
# - "Registered runner"
```

### Step 6: Test Task Runner Connection

```bash
# Check task runner logs
docker logs n8n-task-runner-js | grep -i "connected\|registered"

# Should see:
# "Registered runner" or "Task runner connected"

# Check broker logs
docker logs n8n-task-broker | grep -i "runner\|broker"

# Should see:
# "Task Broker ready" or "Runner registered"
```

### Step 7: Functional Testing

**Test OAuth Authentication:**
1. Access n8n at https://workflows.thehealthsuite.co.uk
2. Login with credentials
3. Navigate to Settings → Credentials
4. Test creating/refreshing OAuth credentials
5. **Expected:** Authentication required, credentials work properly

**Test Code Node Execution:**
1. Create a test workflow with a Code node
2. Add simple JavaScript:
   ```javascript
   return [{ json: { message: 'Task runner working!', timestamp: new Date() } }];
   ```
3. Execute workflow manually
4. **Expected:** Code executes successfully via external task runner

**Monitor Task Runner Activity:**
```bash
# Watch task runner logs during Code node execution
docker logs -f n8n-task-runner-js

# Should see task execution logs when Code nodes run
```

## Post-Deployment

### Monitor Service Health

```bash
# Check health status
docker compose -f docker-compose.production.yml ps

# Monitor resource usage
docker stats n8n-production n8n-task-runner-js n8n-task-broker

# Watch logs for errors
docker compose -f docker-compose.production.yml logs -f
```

### Performance Baseline

**Document baseline metrics:**
- [ ] Code node execution time
- [ ] Workflow execution time
- [ ] Container memory usage
- [ ] Container CPU usage
- [ ] Disk space usage

### Update Monitoring

**Add to monitoring system:**
- Container health checks
- Task runner availability
- Task execution metrics
- Error rate tracking

## Rollback Procedure

If issues occur that cannot be resolved quickly:

### Quick Rollback

```bash
# Stop v2.0 services
docker compose -f docker-compose.production.yml down

# Restore from backup
docker run --rm \
  -v n8n_data:/data \
  -v $(pwd)/backups:/backup \
  alpine tar xzf /backup/n8n-backup-YYYYMMDD-HHMMSS.tar.gz -C /

# Start with v1.x configuration (if kept as docker-compose.production.v1.yml)
docker compose -f docker-compose.production.v1.yml up -d
```

### Temporary Workaround (Not Recommended)

If only task runners are problematic:

```bash
# Switch to internal task runners temporarily
# Edit docker-compose.production.yml:
# - N8N_RUNNERS_MODE=internal  # Change from external

# Remove task runner services (comment out in compose file)
# Restart
docker compose -f docker-compose.production.yml up -d
```

**Note:** Document why rollback was needed and create ticket for resolution.

## Troubleshooting

### Task Runner Not Connecting

**Symptom:** Code nodes fail to execute

**Check:**
```bash
# Verify grant token is set
docker exec n8n-task-runner-js env | grep N8N_RUNNERS_GRANT_TOKEN

# Check network connectivity
docker exec n8n-task-runner-js ping n8n-task-broker

# Review logs
docker logs n8n-task-runner-js
docker logs n8n-task-broker
```

**Common Causes:**
- Missing or incorrect `N8N_RUNNERS_GRANT_TOKEN`
- Network connectivity issues
- Task broker not running

### OAuth Authentication Issues

**Symptom:** OAuth flows fail or require re-authentication

**Check:**
```bash
# Verify OAuth callback setting
docker exec n8n-production env | grep N8N_SKIP_AUTH_ON_OAUTH_CALLBACK

# Should be: N8N_SKIP_AUTH_ON_OAUTH_CALLBACK=false
```

**Solution:**
- Ensure users are logged in before OAuth authentication
- Clear browser cache and try again
- Check OAuth callback URLs in provider settings

### High Resource Usage

**Symptom:** Task runner consuming excessive resources

**Check:**
```bash
docker stats n8n-task-runner-js

# Monitor during workflow execution
```

**Solutions:**
- Limit concurrent task executions
- Add resource constraints to docker-compose:
  ```yaml
  n8n-task-runner:
    deploy:
      resources:
        limits:
          cpus: '1'
          memory: 1G
  ```

## Security Checklist

Post-deployment security verification:

- [ ] OAuth authentication requires user login
- [ ] Task runners isolated in separate containers
- [ ] Grant token is secure and not exposed
- [ ] HTTPS configured and working
- [ ] All containers running with minimal privileges
- [ ] Network isolation verified
- [ ] No sensitive data in logs
- [ ] Backup encryption configured (if applicable)

## Success Criteria

Deployment is successful when:

- ✅ All three containers running and healthy
- ✅ OAuth authentication working with security enabled
- ✅ Code nodes execute successfully via external runner
- ✅ No errors in logs for 24 hours
- ✅ Workflows executing as expected
- ✅ Performance meets or exceeds baseline
- ✅ Monitoring alerts configured

## Next Steps

After successful deployment:

1. **Monitor for 48 hours**
   - Watch for any errors or performance issues
   - Verify all workflows continue functioning

2. **Update Documentation**
   - Mark deployment as complete in migration guide
   - Document any issues encountered and solutions

3. **Team Communication**
   - Notify team of v2.0 deployment
   - Share OAuth authentication changes
   - Provide troubleshooting contact

4. **Schedule Follow-up**
   - Review metrics after 1 week
   - Optimize resource allocation if needed
   - Plan for any additional v2.0 features

---

**Deployment Date:** _____________  
**Deployed By:** _____________  
**Rollback Plan Tested:** ☐ Yes ☐ No  
**Monitoring Configured:** ☐ Yes ☐ No  
**Team Notified:** ☐ Yes ☐ No
