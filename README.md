# Build openresty with proxy-connect module
```bash
docker build -f Dockerfile-openresty -t openresty-proxy-connect:1.0.0 .
```

# Build docker registry proxy based on openresty with htpasswd
```bash
docker build -f Dockerfile -t openresty-docker-registry-proxy:1.0.0 .
```

# Run docker registry proxy sample (user1:user1 user2:user2)
```bash
docker run --name openresty_docker_registry_proxy --rm -it \
  -p 3128:3128 \
  -v $(pwd)/docker_mirror_cache:/docker_mirror_cache \
  -v $(pwd)/certs:/certs \
  -e REGISTRIES="own-registry.sample.com" \
  -e VERIFY_SSL="false" \
  -e HTPASSWD='user1:$apr1$OvGg62Jt$Tg2r7b0nu9LHYtthKBGva/ user2:$apr1$FMKFApNl$47e0wnD8ajeh.B2u64lLI.' \
  -e AUTH_REGISTRIES="own-registry.sample.com:admin:password" \
  -e CACHE_MAX_SIZE="1G" \
  -e ALLOW_PUSH="true" \
  -e ENABLE_MANIFEST_CACHE="true" \
  openresty-docker-registry-proxy:1.0.0
```

The `HTPASSWD` environment variable activates basic authentication. In this example, we define two users:
* user1:user1
* user2:user2

The `HTPASSWD_DELIMITER` environment variable can be used to specify a custom delimiter. By default, a `space` is used.

By default, `generate-certificate.sh` generates a self-signed certificate. You can override this by mounting a volume with your own certificates at `/certs`.
* server.crt
* server.key

# Configure docker to use a proxy
```json
{
  ...
  "proxies": {
    "http-proxy": "http://user1:user1@127.0.0.1:3128",
    "https-proxy": "http://user1:user1@127.0.0.1:3128"
  },
  "insecure-registries" : ["own-registry.sample.com:443"]
}
```

The `insecure-registries` setting should be configured if your registry is using an invalid or self-signed certificate.
