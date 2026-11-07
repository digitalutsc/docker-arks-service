# No plugin

The default build context for `plugin` (see `ARKS_PLUGIN_SRC` in `.env.example`).
It deliberately holds no `pyproject.toml`, so the image is arks-service alone.
To build the optional command line into the image, set `ARKS_PLUGIN_SRC` to an
`arks-cli` checkout and `ARKS_PLUGINS=arks_cli`, then `make install`.
