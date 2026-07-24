# Security

## Report a vulnerability

Do not open a public issue for a vulnerability that could expose a vault,
credential, private attachment, or remote runner. Use GitHub's private
vulnerability reporting for this repository.

Include the affected version, impact, reproduction steps, and any suggested
mitigation. Do not include real vault content or live credentials.

## Deployment boundary

This repository contains application source only. A Brain vault, OAuth client,
bot token, device token, Cloudflare token, Apple signing certificate, and
machine-specific generated configuration must stay outside Git.

Local mode requires no network service. Remote mode is self-hosted and each
operator is responsible for access control, credential rotation, backups, and
Cloudflare account security.
