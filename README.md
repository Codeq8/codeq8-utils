# Codeq8 Utils

Public helper actions for Codeq8 workflows.

Current contents:

- Root action: persistent workspace checkout

Example usage:

```yml
- uses: Codeq8/codeq8-utils@main
  with:
    github_token: ${{ github.token }}
    target_sha: ${{ github.sha }}
    fallback_ref: ${{ github.ref }}
```
