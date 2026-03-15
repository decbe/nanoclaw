#!/bin/bash
# Auto-fix for credential proxy base path issue
# Run this after updating from upstream if you use custom API endpoints
#
# Usage: ./scripts/fix-credential-proxy.sh [--check]
#   --check: Only check if fix is needed, don't apply changes

set -e

CHECK_ONLY=false
if [[ "$1" == "--check" ]]; then
  CHECK_ONLY=true
fi

echo "======================================"
echo "Credential Proxy Base Path Fix Check"
echo "======================================"
echo ""

# Check if fix is needed
if grep -q "const basePath = upstreamUrl.pathname" src/credential-proxy.ts; then
  echo "✅ Fix already present - no action needed"
  echo ""
  echo "Your credential proxy correctly handles custom API endpoints:"
  echo "  • GLM API: https://open.bigmodel.cn/api/anthropic"
  echo "  • Azure: https://your-resource.openai.azure.com/openai/deployments/claude"
  echo "  • Local proxies: http://localhost:8080/proxy"
  exit 0
fi

if grep -q "path: req.url," src/credential-proxy.ts; then
  echo "⚠️  Fix needed!"
  echo ""
  echo "Problem: Credential proxy loses base path for custom API endpoints"
  echo "Impact: 405 errors when using GLM API, Azure, or local proxies"
  echo ""

  if $CHECK_ONLY; then
    echo "Run without --check to apply fix automatically"
    exit 1
  fi

  echo "Applying fix..."

  # Create backup
  BACKUP_FILE="src/credential-proxy.ts.backup-$(date +%Y%m%d-%H%M%S)"
  cp src/credential-proxy.ts "$BACKUP_FILE"
  echo "✓ Backup created: $BACKUP_FILE"

  # Detect sed variant
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_CMD=gsed
    if ! command -v gsed &> /dev/null; then
      echo "❌ Error: gsed required on macOS"
      echo "Install with: brew install gnu-sed"
      exit 1
    fi
  else
    SED_CMD=sed
  fi

  # Apply fix
  # Insert base path logic before makeRequest
  $SED_CMD -i '/const upstream = makeRequest(/i\
        // Combine upstream base path with request path\
        // This is necessary for custom API endpoints (e.g., https://open.bigmodel.cn/api/anthropic)\
        // where the base URL contains a path prefix that must be preserved\
        const basePath = upstreamUrl.pathname.replace(/\\/\\/$/, '"'"''"'"');\
        const requestPath = req.url || '"'"'/'"'"';\
        const fullPath = basePath + requestPath;\
' src/credential-proxy.ts

  # Replace req.url with fullPath
  $SED_CMD -i 's/path: req.url,/path: fullPath,/' src/credential-proxy.ts

  echo "✓ Fix applied to src/credential-proxy.ts"

  # Rebuild
  echo "✓ Rebuilding project..."
  npm run build > /dev/null 2>&1

  echo ""
  echo "✅ Fix applied successfully!"
  echo ""
  echo "Changes:"
  echo "  • Added base path extraction: upstreamUrl.pathname"
  echo "  • Concatenated base path + request path"
  echo "  • Preserves custom API endpoint paths (e.g., /api/anthropic)"
  echo ""
  echo "Next steps:"
  echo "  1. Review changes: git diff src/credential-proxy.ts"
  echo "  2. Restart service: systemctl --user restart nanoclaw"
  echo "  3. Test with a message to verify"
  echo ""
  echo "To undo: cp $BACKUP_FILE src/credential-proxy.ts && npm run build"

else
  echo "⚠️  Unexpected state - manual review required"
  echo ""
  echo "Expected pattern not found in src/credential-proxy.ts"
  echo "The file may have been modified or the issue already fixed differently."
  echo ""
  echo "Manual check:"
  echo "  grep -A 10 'const upstream = makeRequest' src/credential-proxy.ts"
  exit 1
fi
