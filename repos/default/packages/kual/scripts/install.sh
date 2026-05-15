#!/bin/sh
set -eu

if [ ! -d /mnt/us ]; then
    echo "Kindle user storage /mnt/us not found"
    exit 1
fi

mkdir -p /mnt/us/extensions/kual
mkdir -p /mnt/us/documents

cat > /mnt/us/documents/zen-kual.sh <<'EOF'
#!/bin/sh
# Name: Zen KUAL Check
# Author: ZenPackageManager
# DontUseFBInk
echo "KUAL placeholder installed by Zen Package Manager"
EOF

chmod +x /mnt/us/documents/zen-kual.sh

echo "KUAL placeholder install complete"
