# MyScript Lua client

Install locally:

```bash
luarocks install --local luasocket
luarocks install --local luasec
luarocks install --local lua-cjson
luarocks install --local luaossl
eval "$(luarocks path --bin --local)"
```

Run:

```bash
export MYSCRIPT_APPLICATION_KEY="..."
export MYSCRIPT_HMAC_KEY="..."
export MYSCRIPT_LANGUAGE="fr_FR"
lua example_recognize.lua pencil_strokes.lua /etc/ssl/certs/ca-certificates.crt
```

Set `MYSCRIPT_DEBUG=1` to print the exact JSON payload.
