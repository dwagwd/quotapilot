# Codex plugin integration

The companion app works independently of the Codex plugin. The plugin provides a discoverable launch and configuration skill; it does not inject UI into Codex or Pet.

The checkout contains `.codex-plugin/plugin.json` and `skills/usage-widget/SKILL.md`. To register a local checkout in your personal Codex marketplace, ask Codex to use its **plugin-creator** skill to register this plugin and install it. Use a new Codex task after installation or updates so the latest skill is loaded.

The launch skill runs the bundled `scripts/launch.sh`, which builds/installs the companion only if it is missing. To update the installed app after changing source, run `scripts/build-install.sh` explicitly.

The public source repository is [dwagwd/quotapilot](https://github.com/dwagwd/quotapilot). It is not listed in an official curated marketplace. Use the standalone installation above or register your local checkout through the plugin-creator flow. See [official plugin documentation](https://learn.chatgpt.com/docs/plugins) for current packaging and distribution options.
