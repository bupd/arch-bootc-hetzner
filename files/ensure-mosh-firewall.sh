#!/bin/bash
set -euo pipefail

rule_present() {
    local rules_file="$1"
    grep -Fq '### tuple ### allow udp 60000:61000 0.0.0.0/0 any 0.0.0.0/0' "$rules_file"
}

rule6_present() {
    local rules_file="$1"
    grep -Fq '### tuple ### allow udp 60000:61000 ::/0 any ::/0' "$rules_file"
}

if ! rule_present /etc/ufw/user.rules; then
    ufw allow 60000:61000/udp
fi

if ! rule6_present /etc/ufw/user6.rules; then
    ufw allow 60000:61000/udp
fi
