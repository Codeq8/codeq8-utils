# Codeq8 Utils

Public helper actions for Codeq8 self-hosted runner workflows.

## Included actions

- Root action: persistent workspace checkout

## `Codeq8/codeq8-utils@main`

Syncs the current repository into a persistent self-hosted runner workspace without
cleaning ignored files from that workspace.

Behavior:

- reuses the existing checkout in `GITHUB_WORKSPACE` when possible
- fetches an explicit SHA when one is available
- falls back to a requested or workflow ref when needed
- restores the public `origin` URL after authenticated fetches
- keeps ignored files in place instead of running `git clean -ffdx`
- optionally syncs Git LFS payloads

Inputs:

- `github_token`: token used to fetch the target repository
- `requested_ref`: optional ref from a `repository_dispatch` payload
- `requested_sha`: optional SHA from a `repository_dispatch` payload
- `target_sha`: exact commit SHA to checkout
- `fallback_ref`: ref to fetch when the target SHA is unavailable
- `sync_lfs`: set to `"true"` to run `git lfs pull`

Example:

```yml
- uses: Codeq8/codeq8-utils@main
  with:
    github_token: ${{ github.token }}
    requested_ref: ${{ github.event.client_payload.requested_ref }}
    requested_sha: ${{ github.event.client_payload.requested_sha }}
    target_sha: ${{ github.sha }}
    fallback_ref: ${{ github.ref }}
    sync_lfs: "false"
```
