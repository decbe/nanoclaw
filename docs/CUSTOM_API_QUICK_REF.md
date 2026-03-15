# Quick Reference: Custom API Endpoints

## Do You Need the Base Path Fix?

Check your `.env` file:

```bash
# Check if your ANTHROPIC_BASE_URL has a path after the domain
grep ANTHROPIC_BASE_URL .env
```

| Pattern | Needs Fix? | Example |
|---------|-----------|---------|
| `https://api.anthropic.com` | ❌ No | Standard Anthropic API |
| `https://open.bigmodel.cn/api/anthropic` | ✅ Yes | GLM API (has `/api/anthropic`) |
| `https://your-resource.azure.com/openai/deployments/claude` | ✅ Yes | Azure (has `/openai/deployments/claude`) |
| `http://localhost:8080/proxy` | ✅ Yes | Local proxy (has `/proxy`) |
| `http://localhost:8000` | ❌ No | Local API (no path after domain) |

## Quick Fix

```bash
# Check if fix is needed
./scripts/fix-credential-proxy.sh --check

# Apply fix if needed
./scripts/fix-credential-proxy.sh

# Restart service
systemctl --user restart nanoclaw
```

## After Updating from Upstream

Always run this after `git pull upstream main`:

```bash
./scripts/fix-credential-proxy.sh --check || ./scripts/fix-credential-proxy.sh
```

## Error to Watch For

If you see this in logs:
```
API Error: 405 <!doctypehtml>...
```

It means the base path fix is missing!

## Full Documentation

- [Detailed Fix Documentation](CREDENTIAL_PROXY_BASE_PATH_FIX.md)
- [Post-Update Checklist](POST_UPDATE_CHECKLIST.md)
