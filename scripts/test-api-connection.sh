#!/bin/bash

##
# API Connection Test Script
# Tests basic connectivity to Semble API with real credentials
# @fileoverview Simple API connection validation script
# @author Mike Hatcher
# @website https://github.com/mikehatcher/n8n-nodes-semble
# @namespace n8n-nodes-semble.scripts
##

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Semble API Connection Test ===${NC}"

# Check for required environment variable
if [ -z "$SEMBLE_API_TOKEN" ]; then
    echo -e "${RED}❌ Error: SEMBLE_API_TOKEN environment variable is not set${NC}"
    echo "Please set your Semble API token:"
    echo "export SEMBLE_API_TOKEN=your_token_here"
    exit 1
fi

echo -e "${YELLOW}🔑 Testing API connection...${NC}"

# Simple connection test - just get a single patient
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "x-token: $SEMBLE_API_TOKEN" \
    -d '{
        "query": "query { patients(pagination: { page: 1, pageSize: 1 }) { data { id firstName lastName } } }"
    }' \
    https://open.semble.io/graphql)

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
# Extract response body (all but last line) - BSD compatible
BODY=$(echo "$RESPONSE" | sed '$d')

echo -e "${YELLOW}HTTP Status: $HTTP_CODE${NC}"

if [ "$HTTP_CODE" = "200" ]; then
    # Check if response contains data or errors
    if echo "$BODY" | grep -q '"errors"'; then
        echo -e "${RED}❌ API Error Response:${NC}"
        echo "$BODY" | jq '.errors' 2>/dev/null || echo "$BODY"
        exit 1
    elif echo "$BODY" | grep -q '"data"'; then
        echo -e "${GREEN}✅ API Connection Successful!${NC}"
        echo -e "${GREEN}📊 Response preview:${NC}"
        echo "$BODY" | jq '.data.patients.data[0] // "No patients found"' 2>/dev/null || echo "$BODY"
        echo ""
        echo -e "${GREEN}🎉 Ready to proceed with development!${NC}"
    else
        echo -e "${RED}❌ Unexpected response format:${NC}"
        echo "$BODY"
        exit 1
    fi
else
    echo -e "${RED}❌ API Connection Failed${NC}"
    echo "Response body:"
    echo "$BODY"
    exit 1
fi
