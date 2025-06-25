#! /bin/bash

echo "Entrypoint starting."

set -Eeuo pipefail
trap "echo TRAPed signal" HUP INT QUIT TERM

# configure nginx DNS settings to match host, why must we do that nginx?
# this leads to a world of problems. ipv6 format being different, etc.
# below is a collection of hacks contributed over the years.

echo "-- resolv.conf:"
cat /etc/resolv.conf
echo "-- end resolv"

# Podman adds a "%3" to the end of the last resolver? I don't get it. Strip it out.
export RESOLVERS=$(cat /etc/resolv.conf | sed -e 's/%3//g' | awk '$1 == "nameserver" {print ($2 ~ ":")? "["$2"]": $2}' ORS=' ' | sed 's/ *$//g')
if [ "x$RESOLVERS" = "x" ]; then
  echo "Warning: unable to determine DNS resolvers for nginx" >&2
  exit 66
fi

echo "DEBUG, determined RESOLVERS from /etc/resolv.conf: '$RESOLVERS'"

conf=""
for ONE_RESOLVER in ${RESOLVERS}; do
  echo "Possible resolver: $ONE_RESOLVER"
  conf="resolver $ONE_RESOLVER; "
done

echo "Final chosen resolver: $conf"
confpath=/opt/openresty/nginx/conf/resolvers.conf
if [ ! -e $confpath ]; then
  echo "Using auto-determined resolver '$conf' via '$confpath'"
  if [[ "a${DISABLE_IPV6}" == "atrue" ]]; then
    echo "Disabling IPv6 in '$confpath'"
    conf="${conf%;*} ipv6=off;"
  fi
  echo "$conf" >$confpath
else
  echo "Not using resolver config, keep existing '$confpath' -- mounted by user?"
fi

# Interceptions map, which are the hosts that will be handled by the caching part.
# It should list exactly the same hosts we have created certificates for -- if not, Docker will get TLS errors, of course.
echo -n "" >/opt/openresty/nginx/conf/docker.intercept.map

# Some hosts/registries are always needed, but others can be configured in env var REGISTRIES
for ONEREGISTRYIN in docker.caching.proxy.internal registry-1.docker.io auth.docker.io ${REGISTRIES}; do
  ONEREGISTRY=$(echo ${ONEREGISTRYIN} | xargs) # Remove whitespace
  echo "${ONEREGISTRY} 127.0.0.1:443;" >>/opt/openresty/nginx/conf/docker.intercept.map
done

# Clean the list and generate certificates.
/generate-certificate.sh

# Target host interception. Empty by default. Used to intercept outgoing requests
# from the proxy to the registries.
echo -n "" >/opt/openresty/nginx/conf/docker.targetHost.map

# Now handle the auth part.
echo -n "" >/opt/openresty/nginx/conf/docker.auth.map

# Only configure auth registries if the env var contains values
if [ "$AUTH_REGISTRIES" ]; then
  # Ref: https://stackoverflow.com/a/47633817/219530
  AUTH_REGISTRIES_DELIMITER=${AUTH_REGISTRIES_DELIMITER:-" "}
  s=$AUTH_REGISTRIES$AUTH_REGISTRIES_DELIMITER
  auth_array=()
  while [[ $s ]]; do
    auth_array+=("${s%%"$AUTH_REGISTRIES_DELIMITER"*}")
    s=${s#*"$AUTH_REGISTRIES_DELIMITER"}
  done

  AUTH_REGISTRY_DELIMITER=${AUTH_REGISTRY_DELIMITER:-":"}

  for ONEREGISTRY in "${auth_array[@]}"; do
    s=$ONEREGISTRY$AUTH_REGISTRY_DELIMITER
    registry_array=()
    while [[ $s ]]; do
      registry_array+=("${s%%"$AUTH_REGISTRY_DELIMITER"*}")
      s=${s#*"$AUTH_REGISTRY_DELIMITER"}
    done
    AUTH_HOST="${registry_array[0]}"
    AUTH_USER="${registry_array[1]}"
    AUTH_PASS="${registry_array[2]}"
    AUTH_BASE64=$(echo -n ${AUTH_USER}:${AUTH_PASS} | base64 -w0 | xargs)
    echo "Adding Auth for registry '${AUTH_HOST}' with user '${AUTH_USER}'."
    echo "\"${AUTH_HOST}\" \"${AUTH_BASE64}\";" >>/opt/openresty/nginx/conf/docker.auth.map
  done
fi

# create default config for the caching layer to listen on 443.
echo "        listen 443 ssl default_server;" >/opt/openresty/nginx/conf/caching.layer.listen

# Set Docker Registry cache size, by default, 32 GB ('32g')
CACHE_MAX_SIZE=${CACHE_MAX_SIZE:-32g}

# The cache directory. This can get huge. Better to use a Docker volume pointing here!
# Set to 32gb which should be enough
echo "proxy_cache_path /docker_mirror_cache levels=1:2 max_size=$CACHE_MAX_SIZE inactive=60d keys_zone=cache:10m use_temp_path=off;" >/opt/openresty/nginx/conf/cache_max_size.conf

# Manifest caching configuration. We generate config based on the environment vars.
echo -n "" >/opt/openresty/nginx/conf/nginx.manifest.caching.config.conf

[[ "a${ENABLE_MANIFEST_CACHE}" == "atrue" ]] && [[ "a${MANIFEST_CACHE_PRIMARY_REGEX}" != "a" ]] && cat <<EOD >>/opt/openresty/nginx/conf/nginx.manifest.caching.config.conf
    # First tier caching of manifests; configure via MANIFEST_CACHE_PRIMARY_REGEX and MANIFEST_CACHE_PRIMARY_TIME
    location ~ ^/v2/(.*)/manifests/${MANIFEST_CACHE_PRIMARY_REGEX} {
        set \$docker_proxy_request_type "manifest-primary";
        proxy_cache_valid ${MANIFEST_CACHE_PRIMARY_TIME};
        include "/opt/openresty/nginx/conf/nginx.manifest.stale.conf";
    }
EOD

[[ "a${ENABLE_MANIFEST_CACHE}" == "atrue" ]] && [[ "a${MANIFEST_CACHE_SECONDARY_REGEX}" != "a" ]] && cat <<EOD >>/opt/openresty/nginx/conf/nginx.manifest.caching.config.conf
    # Secondary tier caching of manifests; configure via MANIFEST_CACHE_SECONDARY_REGEX and MANIFEST_CACHE_SECONDARY_TIME
    location ~ ^/v2/(.*)/manifests/${MANIFEST_CACHE_SECONDARY_REGEX} {
        set \$docker_proxy_request_type "manifest-secondary";
        proxy_cache_valid ${MANIFEST_CACHE_SECONDARY_TIME};
        include "/opt/openresty/nginx/conf/nginx.manifest.stale.conf";
    }
EOD

[[ "a${ENABLE_MANIFEST_CACHE}" == "atrue" ]] && cat <<EOD >>/opt/openresty/nginx/conf/nginx.manifest.caching.config.conf
    # Default tier caching for manifests. Caches for ${MANIFEST_CACHE_DEFAULT_TIME} (from MANIFEST_CACHE_DEFAULT_TIME)
    location ~ ^/v2/(.*)/manifests/ {
        set \$docker_proxy_request_type "manifest-default";
        proxy_cache_valid ${MANIFEST_CACHE_DEFAULT_TIME};
        include "/opt/openresty/nginx/conf/nginx.manifest.stale.conf";
    }
EOD

[[ "a${ENABLE_MANIFEST_CACHE}" != "atrue" ]] && cat <<EOD >>/opt/openresty/nginx/conf/nginx.manifest.caching.config.conf
    # Manifest caching is disabled. Enable it with ENABLE_MANIFEST_CACHE=true
    location ~ ^/v2/(.*)/manifests/ {
        set \$docker_proxy_request_type "manifest-default-disabled";
        proxy_cache_valid 0s;
        include "/opt/openresty/nginx/conf/nginx.manifest.stale.conf";
    }
EOD

echo -e "\nManifest caching config: ---\n"
cat /opt/openresty/nginx/conf/nginx.manifest.caching.config.conf
echo "---"

if [[ "a${ALLOW_PUSH}" == "atrue" ]]; then
  cat <<EOF >/opt/openresty/nginx/conf/allowed.methods.conf
    # allow to upload big layers
    client_max_body_size 0;

    # only cache GET requests
    proxy_cache_methods GET;
EOF
else
  cat <<'EOF' >/opt/openresty/nginx/conf/allowed.methods.conf
    # Block POST/PUT/DELETE. Don't use this proxy for pushing.
    if ($request_method = POST) {
        return 405 "POST method is not allowed";
    }
    if ($request_method = PUT) {
        return 405 "PUT method is not allowed";
    }
    if ($request_method = DELETE) {
        return 405  "DELETE method is not allowed";
    }
EOF
fi

# Only configure htpasswd if the env var exists
if [[ -z ${HTPASSWD+set} ]]; then
  echo "" >/opt/openresty/nginx/conf/htpasswd.conf
else
  HTPASSWD_DELIMITER=${HTPASSWD_DELIMITER:-" "}
  s=$HTPASSWD$HTPASSWD_DELIMITER
  auth_array=()
  while [[ $s ]]; do
    auth_array+=("${s%%"$HTPASSWD_DELIMITER"*}")
    s=${s#*"$HTPASSWD_DELIMITER"}
  done

  for ONEHTPASSWD in "${auth_array[@]}"; do
    echo "Adding htpasswd entry for user '${ONEHTPASSWD%%:*}'."
    echo ${ONEHTPASSWD} >>/opt/openresty/nginx/conf/.htpasswd
  done

  cat <<EOF >/opt/openresty/nginx/conf/htpasswd.conf
    auth_basic "Restricted Content";
    auth_basic_user_file /opt/openresty/nginx/conf/.htpasswd;

    rewrite_by_lua_file /opt/openresty/nginx/conf/proxy_auth.lua;
EOF
fi

# normally use non-debug version of nginx
NGINX_BIN="/opt/openresty/bin/openresty"

# Timeout configurations
echo "" >/opt/openresty/nginx/conf/nginx.timeouts.config.conf
cat <<EOD >>/opt/openresty/nginx/conf/nginx.timeouts.config.conf
  # Timeouts

  # ngx_http_core_module
  keepalive_timeout  ${KEEPALIVE_TIMEOUT};
  send_timeout ${SEND_TIMEOUT};
  client_body_timeout ${CLIENT_BODY_TIMEOUT};
  client_header_timeout ${CLIENT_HEADER_TIMEOUT};

  # ngx_http_proxy_module
  proxy_read_timeout ${PROXY_READ_TIMEOUT};
  proxy_connect_timeout ${PROXY_CONNECT_TIMEOUT};
  proxy_send_timeout ${PROXY_SEND_TIMEOUT};

  # ngx_http_proxy_connect_module - external module
  proxy_connect_read_timeout ${PROXY_CONNECT_READ_TIMEOUT};
  proxy_connect_connect_timeout ${PROXY_CONNECT_CONNECT_TIMEOUT};
  proxy_connect_send_timeout ${PROXY_CONNECT_SEND_TIMEOUT};
EOD

echo -e "\nTimeout configs: ---"
cat /opt/openresty/nginx/conf/nginx.timeouts.config.conf
echo -e "---\n"

# Request buffering
echo "" >/opt/openresty/nginx/conf/proxy.request.buffering.conf
if [[ "a${PROXY_REQUEST_BUFFERING}" == "afalse" ]]; then
  cat <<EOD >/opt/openresty/nginx/conf/proxy.request.buffering.conf
  proxy_max_temp_file_size 0;
  proxy_request_buffering off;
  proxy_http_version 1.1;
EOD
fi

echo -e "\nRequest buffering: ---"
cat /opt/openresty/nginx/conf/proxy.request.buffering.conf
echo -e "---\n"

# Upstream SSL verification.
echo "" >/opt/openresty/nginx/conf/docker.verify.ssl.conf
if [[ "a${VERIFY_SSL}" == "atrue" ]]; then
  cat <<EOD >/opt/openresty/nginx/conf/docker.verify.ssl.conf
    # We actually wanna be secure and avoid mitm attacks.
    # Fitting, since this whole thing is a mitm...
    # We'll accept any cert signed by a CA trusted by Mozilla (ca-certificates-bundle in alpine)
    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_ssl_verify_depth 2;
EOD
  echo "Upstream SSL certificate verification enabled."
else
  echo "Upstream SSL certificate verification is DISABLED."
fi

echo -e "\nFinal resolver configuration: ---"
cat "${confpath}"
echo -e "---\n"

echo "Testing nginx config..."
${NGINX_BIN} -t

echo "Starting nginx! Have a nice day."
${NGINX_BIN} -g "daemon off;"
