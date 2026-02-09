# Scan Report

## Commands run

```bash
npx hardhat test
HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= NO_PROXY= npx hardhat test
```

## Findings

- Hardhat attempted to download the Solidity 0.8.20 compiler and failed due to an HTTP proxy tunneling error (403) when using the default environment.
- Attempting to bypass the proxy by unsetting `HTTP_PROXY`/`HTTPS_PROXY` still failed because the HTTP client expects proxy settings to be present (`Proxy opts.uri is mandatory`).
- The repo uses Hardhat with Solidity 0.8.20 and `viaIR` enabled; compilation requires downloading that compiler unless a local solc binary is available in Hardhat’s cache.

## Environment observations

- Proxy-related environment variables are set (`HTTP_PROXY`, `HTTPS_PROXY`, `npm_config_http_proxy`, `npm_config_https_proxy`, `YARN_HTTP_PROXY`, `YARN_HTTPS_PROXY`).
- A corporate MITM certificate is configured via `NODE_EXTRA_CA_CERTS`.

## Environment fixes to unblock tests

1. **Ensure proxy settings allow access to `https://binaries.soliditylang.org`.**
   - If the proxy is required, allowlist that host.
2. **Align npm/yarn proxy configuration with the environment.**
   - Update npm config to point at a working proxy or remove invalid entries if direct access is allowed.
3. **Pre-populate Hardhat’s compiler cache** with the `soljson-v0.8.20` build if outbound downloads are blocked.
   - Download the compiler using a trusted host and place it in Hardhat’s compilers cache directory.
4. **If direct access is allowed**, run tests with a clean environment and without proxy variables.

## Notes

- Hardhat is configured for Solidity 0.8.20 and optimizer settings with `viaIR: true`.
