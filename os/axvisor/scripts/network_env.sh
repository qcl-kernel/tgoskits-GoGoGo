# Shared network environment for trusted external build dependencies. Source this
# file instead of duplicating proxy policy in each downloader or package manager.

TGOS_HTTP_PROXY="${TGOS_HTTP_PROXY:-http://172.16.0.254:7897}"
export TGOS_HTTP_PROXY

http_proxy="${http_proxy:-$TGOS_HTTP_PROXY}"
https_proxy="${https_proxy:-$TGOS_HTTP_PROXY}"
HTTP_PROXY="${HTTP_PROXY:-$http_proxy}"
HTTPS_PROXY="${HTTPS_PROXY:-$https_proxy}"
NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1,192.168.0.0/16,172.16.0.0/12}"
no_proxy="${no_proxy:-$NO_PROXY}"
export http_proxy https_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY no_proxy
