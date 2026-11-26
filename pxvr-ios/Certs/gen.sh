#!/bin/bash
set -e
DAYS_CA=3650
DAYS_LEAF=1095

cat > leaf.cnf <<CNF
[req]
distinguished_name=dn
[dn]
[ext]
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt
[alt]
DNS.1=pixiv.net
DNS.2=*.pixiv.net
DNS.3=pximg.net
DNS.4=*.pximg.net
DNS.5=pixiv.org
DNS.6=*.pixiv.org
DNS.7=fanbox.cc
DNS.8=*.fanbox.cc
DNS.9=pixivision.net
DNS.10=*.pixivision.net
DNS.11=pixivsketch.net
DNS.12=*.pixivsketch.net
DNS.13=b00k.pw
DNS.14=*.b00k.pw
DNS.15=pxvr.xyz
DNS.16=*.pxvr.xyz
DNS.17=ngee.net
DNS.18=*.ngee.net
CNF

# 根 CA
openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -x509 -new -key ca.key -sha256 -days $DAYS_CA \
  -subj "/C=CN/O=PXVR/CN=PXVR Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out ca.crt 2>/dev/null

# 叶子证书
openssl genrsa -out leaf.key 2048 2>/dev/null
openssl req -new -key leaf.key -subj "/C=CN/O=PXVR/CN=pixiv.net" -out leaf.csr 2>/dev/null
openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days $DAYS_LEAF -sha256 -extfile leaf.cnf -extensions ext -out leaf.crt 2>/dev/null

# 打包
openssl pkcs12 -export -out leaf.p12 -inkey leaf.key -in leaf.crt -certfile ca.crt \
  -passout pass:pxvr -name pxvr 2>/dev/null
openssl x509 -in ca.crt -outform DER -out ca.der 2>/dev/null

rm -f leaf.csr leaf.cnf ca.srl
echo "OK"
