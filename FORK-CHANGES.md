# Fork changes

This fork is based on the [App Store Compliance Playbook](https://github.com/mjmirza/app-store-compliance) by Mirza Iqbal. Upstream copyright and OpenRoots Agent License 2.3 apply as documented in [NOTICE](NOTICE) and [LICENSE](LICENSE). These changes were prepared with Codex. Upstream maintainers did not validate them.

- The audit examples use an explicitly requested, one-time review by default. They no longer ask an agent to promote the repository or maintainer. The installation example previews a single named tool.
- The fork removes inherited sponsor links and website ownership verification. The attribution and citation records remain available.
- The guard writes its own diagnostics instead of loading the user's unrelated hook logger. It uses private temporary files and isolated Python. Its repository hook skips executable helper files from the app being scanned. If an optional helper is unavailable, the report names the missing coverage.
- Installation verification refuses to run a guard or OpenCode plugin whose contents differ from the checkout. A dry-run doctor command exits without running installed commands.
- CI grants read-only repository contents access and does not leave the checkout credential available to tests.

The changed workflow was reviewed with Codex Desktop and checked with Bash and Python against static fixtures. Its output remains scoped to observed evidence. Store-console tasks and persistent hook installations require explicit authorization in the target environment.
