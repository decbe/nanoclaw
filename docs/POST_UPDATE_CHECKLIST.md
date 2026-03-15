# Post-Update Checklist

Run this checklist after updating from upstream (`git pull upstream main`).

## 1. Check Credential Proxy Fix (Custom API Users)

If you use a custom API endpoint (GLM, Azure, local proxy), run:

```bash
./scripts/fix-credential-proxy.sh --check
```

If it reports fix needed, apply it:
```bash
./scripts/fix-credential-proxy.sh
systemctl --user restart nanoclaw
```

**Why**: Upstream code assumes standard Anthropic API endpoint. Custom endpoints with path prefixes (e.g., `/api/anthropic`) need base path preservation.

See: [docs/CREDENTIAL_PROXY_BASE_PATH_FIX.md](CREDENTIAL_PROXY_BASE_PATH_FIX.md)

## 2. Rebuild Project

```bash
npm run build
```

## 3. Restart Service

```bash
# Linux (systemd)
systemctl --user restart nanoclaw

# macOS (launchd)
launchctl kickstart -k gui/$(id -u)/com.nanoclaw
```

## 4. Verify Service Status

```bash
# Check service is running
systemctl --user status nanoclaw

# Check logs for errors
tail -f logs/nanoclaw.log | grep -iE "error|failed"
```

## 5. Test with a Message

Send a test message through your configured channel (Telegram, WhatsApp, etc.) to verify everything works.

## 6. Check for Breaking Changes

Review these files for configuration changes:
- `.env.example` - New environment variables
- `package.json` - New dependencies
- `src/config.ts` - New configuration options

## 7. Update Dependencies (If Needed)

```bash
npm install
npm run build
```

## Quick Update Command

```bash
# One-liner update (includes fix check)
git pull upstream main && \
  ./scripts/fix-credential-proxy.sh && \
  npm install && \
  npm run build && \
  systemctl --user restart nanoclaw && \
  echo "✅ Update complete!"
```

## Rollback if Issues Occur

```bash
# Check recent commits
git log --oneline -5

# Rollback to previous version
git reset --hard HEAD~1

# Rebuild and restart
npm run build && systemctl --user restart nanoclaw
```
