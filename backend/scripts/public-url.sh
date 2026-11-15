#!/bin/sh
: "${DAYDAYHEALTH_PUBLIC_URL:?Set DAYDAYHEALTH_PUBLIC_URL to your HTTPS backend address}"
printf '%s\n' "$DAYDAYHEALTH_PUBLIC_URL"
