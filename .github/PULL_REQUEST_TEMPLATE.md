<!--
Thanks for contributing. A short PR is the fastest to review.
Delete any section that doesn't apply.
-->

## Summary

<!-- One or two sentences. Why does this PR exist? -->

## What changed

<!-- Bullet list of concrete edits -->

## Testing

<!--
How you exercised it. If there's no unit test, describe the manual run:
simulator / device, network (mainnet vs testnet), wallet used, the exact
flow. For anything touching `Signing/` note whether you verified against
the Python SDK.
-->

## Notes for reviewers

<!--
Anything worth calling attention to — tricky trade-offs, follow-up PRs
you plan to send, areas you'd like a sanity check on.
-->

## Checklist

- [ ] `xcodegen generate` still produces a clean project
- [ ] Builds without warnings on Xcode 15.3+
- [ ] No personal identifiers (DEVELOPMENT_TEAM, REOWN_PROJECT_ID, wallet
      addresses, email addresses) in the diff
- [ ] WS / signing changes verified against at least one real account
