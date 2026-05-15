#!/bin/sh
set -eu

if [ ! -d /mnt/us ]; then
    echo "Kindle user storage /mnt/us not found"
    exit 1
fi

mkdir -p /mnt/us/koreader
mkdir -p /mnt/us/documents

cat > /mnt/us/koreader/koreader.sh <<'EOF'
#!/bin/sh
echo "KOReader placeholder binary for Kindle"
EOF

chmod +x /mnt/us/koreader/koreader.sh

cat > /mnt/us/documents/koreader.sh <<'EOF'
#!/bin/sh
# Name: KOReader
# Author: ZenPackageManager
# DontUseFBInk
/mnt/us/koreader/koreader.sh --kual --asap
EOF

chmod +x /mnt/us/documents/koreader.sh

echo "KOReader Kindle placeholder install complete"
