# Contributing

Thanks for helping improve Vox Brain.

1. Fork the repository and create a focused branch.
2. Keep personal vault data and deployment credentials outside the checkout.
3. Run `scripts/public-audit` and the relevant test suites before opening a
   pull request.
4. Explain the user-visible change, test coverage, and any migration.

For the complete local verification suite, run:

```sh
scripts/check
```

Never use a real note, email, attachment, domain, account ID, or token as a
test fixture. Use reserved example domains and obviously synthetic identities.
