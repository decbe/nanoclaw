# Credential Proxy Base Path Fix

## Problem

When using custom API endpoints that include a path prefix (e.g., GLM API, Azure, local proxies), the credential proxy fails with **405 Method Not Allowed** errors.

## Symptoms

- Agent responds with: `API Error: 405 <!doctypehtml>...`
- Works fine with standard Anthropic API (`https://api.anthropic.com`)
- Fails with custom endpoints like:
  - GLM: `https://open.bigmodel.cn/api/anthropic`
  - Azure: `https://your-resource.openai.azure.com/openai/deployments/claude`
  - Local proxy: `http://localhost:8080/proxy`

## Root Cause

The credential proxy in `src/credential-proxy.ts` was simplified in upstream and lost the base path concatenation logic.

### Broken Code (upstream/main)
```typescript
const upstream = makeRequest({
  hostname: upstreamUrl.hostname,
  port: upstreamUrl.port || (isHttps ? 443 : 80),
  path: req.url,  // ❌ Only "/v1/messages", missing base path
  method: req.method,
  headers,
});
```

### Fixed Code
```typescript
// Combine upstream base path with request path
// This is necessary for custom API endpoints
const basePath = upstreamUrl.pathname.replace(/\/$/, '');
const requestPath = req.url || '/';
const fullPath = basePath + requestPath;

const upstream = makeRequest({
  hostname: upstreamUrl.hostname,
  port: upstreamUrl.port || (isHttps ? 443 : 80),
  path: fullPath,  // ✅ "/api/anthropic/v1/messages"
  method: req.method,
  headers,
});
```

## When This Fix Is Needed

Check your `.env` file. If `ANTHROPIC_BASE_URL` contains a path after the domain:

```bash
# ✅ Needs this fix (path after domain)
ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic
ANTHROPIC_BASE_URL=https://your-resource.openai.azure.com/openai/deployments/claude
ANTHROPIC_BASE_URL=http://localhost:8080/proxy

# ❌ Doesn't need this fix (no path after domain)
ANTHROPIC_BASE_URL=https://api.anthropic.com
ANTHROPIC_BASE_URL=http://localhost:8000
```

## How to Apply This Fix

### Option 1: Automatic Detection & Fix (Recommended)

Run this command after updating from upstream:

```bash
# Check if fix is needed
if grep -q "path: req.url," src/credential-proxy.ts; then
  echo "⚠️  Base path fix is missing! Applying fix..."

  # Create backup
  cp src/credential-proxy.ts src/credential-proxy.ts.backup

  # Apply fix using sed
  sed -i '/path: req.url,/i\
        // Combine upstream base path with request path\
        // This is necessary for custom API endpoints (e.g., https://open.bigmodel.cn/api/anthropic)\
        // where the base URL contains a path prefix that must be preserved\
        const basePath = upstreamUrl.pathname.replace(/\\/\\/$/, '"'"''"'"');\
        const requestPath = req.url || '"'"'/'"'"';\
        const fullPath = basePath + requestPath;\
' src/credential-proxy.ts

  # Replace req.url with fullPath
  sed -i 's/path: req.url,/path: fullPath,/' src/credential-proxy.ts

  # Rebuild
  npm run build

  echo "✅ Fix applied successfully!"
else
  echo "✅ Base path fix already present, no action needed."
fi
```

### Option 2: Manual Fix

1. Open `src/credential-proxy.ts`
2. Find this section (around line 82-89):
```typescript
const upstream = makeRequest(
  {
    hostname: upstreamUrl.hostname,
    port: upstreamUrl.port || (isHttps ? 443 : 80),
    path: req.url,
    method: req.method,
    headers,
  } as RequestOptions,
```

3. Replace with:
```typescript
// Combine upstream base path with request path
// This is necessary for custom API endpoints (e.g., https://open.bigmodel.cn/api/anthropic)
// where the base URL contains a path prefix that must be preserved
const basePath = upstreamUrl.pathname.replace(/\/$/, '');
const requestPath = req.url || '/';
const fullPath = basePath + requestPath;

const upstream = makeRequest(
  {
    hostname: upstreamUrl.hostname,
    port: upstreamUrl.port || (isHttps ? 443 : 80),
    path: fullPath,
    method: req.method,
    headers,
  } as RequestOptions,
```

4. Rebuild and restart:
```bash
npm run build
systemctl --user restart nanoclaw
```

## Verification

After applying the fix, test with a simple message:

```bash
# Check logs for errors
tail -f logs/nanoclaw.log | grep -iE "405|error"

# Should see successful API calls, not 405 errors
```

## Why This Happens

### Architecture Context

The credential proxy works as a middleware:

1. **Container SDK** sends requests to `http://host.docker.internal:3001/v1/messages`
2. **Credential Proxy** receives request at `req.url = "/v1/messages"`
3. **Credential Proxy** forwards to real API (from `.env`)

The problem: `ANTHROPIC_BASE_URL` serves two purposes:
- **Hostname extraction**: `open.bigmodel.cn`
- **Path prefix**: `/api/anthropic` (this was being ignored)

### URL Breakdown

```
ANTHROPIC_BASE_URL = https://open.bigmodel.cn/api/anthropic
                      ↑ hostname           ↑ pathname
```

Without the fix:
- Request sent: `https://open.bigmodel.cn/v1/messages` ❌ (405)
- Should send: `https://open.bigmodel.cn/api/anthropic/v1/messages` ✅

## Compatibility

This fix is **fully backward compatible**:

- ✅ Standard API: `https://api.anthropic.com` (pathname = "/", no effect)
- ✅ Custom API: `https://open.bigmodel.cn/api/anthropic` (pathname = "/api/anthropic")
- ✅ Local proxy: `http://localhost:8080/proxy` (pathname = "/proxy")

## Upstream Status

This is a **compatibility regression** in upstream. The fix preserves behavior that was removed during a refactoring.

### Related Upstream Issue

If this affects you, consider reporting to upstream:
- Issue: "Credential proxy loses base path for custom API endpoints"
- Impact: GLM API, Azure, local proxies fail with 405 errors
- Fix: Preserve `upstreamUrl.pathname` concatenation

## Automatic Fix Script (Standalone)

Create `scripts/fix-credential-proxy.sh`:

```bash
#!/bin/bash
# Auto-fix for credential proxy base path issue
# Run this after updating from upstream if you use custom API endpoints

set -e

echo "Checking credential proxy base path fix..."

if grep -q "path: req.url," src/credential-proxy.ts; then
  echo "⚠️  Fix needed! Applying..."

  # Backup
  cp src/credential-proxy.ts src/credential-proxy.ts.bak

  # Apply fix (requires gnu-sed on macOS)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_CMD=gsed
    if ! command -v gsed &> /dev/null; then
      echo "Error: gsed required on macOS. Install with: brew install gnu-sed"
      exit 1
    fi
  else
    SED_CMD=sed
  fi

  # Insert base path logic before the request
  $SED_CMD -i '/const upstream = makeRequest(/i\
        // Combine upstream base path with request path\
        const basePath = upstreamUrl.pathname.replace(/\\/\\/$/, '"'"''"'"');\
        const requestPath = req.url || '"'"'/'"'"';\
        const fullPath = basePath + requestPath;\
' src/credential-proxy.ts

  # Replace req.url with fullPath
  $SED_CMD -i 's/path: req.url,/path: fullPath,/' src/credential-proxy.ts

  # Rebuild
  npm run build

  echo "✅ Fix applied! Restart service with: systemctl --user restart nanoclaw"
else
  echo "✅ Fix already present, no action needed."
fi
```

Make executable:
```bash
chmod +x scripts/fix-credential-proxy.sh
```

Run after updates:
```bash
./scripts/fix-credential-proxy.sh
```

## Timeline

- **2026-03-16**: Fix documented after GLM API 405 errors
- **Upstream version**: v1.2.14 (issue introduced)
- **Affected versions**: All versions that lack base path concatenation
