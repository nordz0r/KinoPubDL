# Security Policy

## Supported versions

Security fixes are provided for the latest release. Please update before reporting a vulnerability.

## Reporting a vulnerability

Do not open a public issue for an exploitable vulnerability. Use GitHub's private vulnerability reporting for this repository, or contact the maintainer through the email listed on their GitHub profile. Include the affected version, platform, reproduction steps, and expected impact. Do not attach private files or metadata samples unless they have been sanitized.

## Handling metadata safely

MetaKeep writes metadata sidecars with owner-only permissions where the platform supports them. Sidecars can contain extended-attribute values, filesystem ownership, timestamps, embedded tags (which may include GPS coordinates), HTTP response headers, and source names. The full URL is omitted by default; `--record-url` can store paths and query parameters and should be used only when they contain no credentials or tokens.

Conversion commands are executed without a shell, but the selected converter is an external program and runs with the current user's permissions. Only run converters and process files you trust. Metadata restoration may change permissions, timestamps, ACLs, and extended attributes; review a manifest before restoring data from an untrusted source.
