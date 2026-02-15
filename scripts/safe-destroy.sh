#!/bin/bash
set -e

echo "=== Step 1: Terraform Destroy ==="
terraform destroy -auto-approve || true

echo ""
echo "=== Step 2: Verify Droplets deleted in DigitalOcean ==="
export DIGITALOCEAN_ACCESS_TOKEN=$TF_VAR_do_token
DROPLETS=$(doctl compute droplet list --format Name --no-header | grep -c "^k8s-" || true)

if [ "$DROPLETS" -eq 0 ]; then
    echo "✅ All k8s-* droplets deleted from DigitalOcean"

    echo ""
    echo "=== Step 3: Clean up Terraform State ==="
    if terraform state list | grep -q "."; then
        echo "⚠️  State contains resources - cleaning up..."
        terraform state rm $(terraform state list)
        echo "✅ State cleaned"
    else
        echo "✅ State already clean"
    fi
else
    echo "❌ ERROR: $DROPLETS k8s-* droplets still exist"
    doctl compute droplet list
    exit 1
fi

echo ""
echo "=== Cleanup Complete ==="
