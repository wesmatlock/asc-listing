# Security

`asc-listing` signs App Store Connect API tokens with a private key you give it, and it writes to live App Store listings. Please report anything that could leak that key, a token or an id, or make the tool write something you did not ask for.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting (the Security tab, "Report a vulnerability"). Please do not open a public issue. Expect a reply within a week.

## What the tool does with your credentials

- The `.p8` key is read from the path in `~/.appstoreconnect/config.json` or `ASC_P8_PATH`, and used only to sign short-lived tokens in memory.
- The key, the tokens, the key id and the issuer id are never printed, logged or written to disk. `--verbose` logs only `METHOD path -> status`.
- Requests go only to `api.appstoreconnect.apple.com` and to the upload URLs App Store Connect returns.

Never commit a `.p8` file. If you think a key has been exposed, revoke it in App Store Connect (Users and Access, Integrations) and create a new one.
