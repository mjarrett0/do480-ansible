#!/bin/bash
# Script to generate a TLS Secret with a 1-day certificate for RHACM CertificatePolicy violation
# Generates a self-signed certificate and key, encodes them in base64, and creates create-cert-test.yaml

# Generate self-signed certificate and key with 1-day expiration
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout tls.key -out tls.crt -subj "/CN=test-cert" 2>/dev/null

# Encode certificate and key in base64
TLS_CRT=$(base64 -w 0 tls.crt)
TLS_KEY=$(base64 -w 0 tls.key)

# Create YAML file with Secret resource
cat <<EOF > create-cert-test.yaml
apiVersion: v1
kind: Secret
metadata:
  name: test-cert
  namespace: openshift-ingress
type: kubernetes.io/tls
data:
  # Base64-encoded TLS certificate (expires in 1 day to trigger CertificatePolicy violation)
  tls.crt: $TLS_CRT
  # Base64-encoded RSA private key
  tls.key: $TLS_KEY
EOF

# Clean up temporary files
rm tls.crt tls.key

# Optionally apply the YAML (uncomment to enable)
oc apply -f create-cert-test.yaml
echo "Applied router-cert"