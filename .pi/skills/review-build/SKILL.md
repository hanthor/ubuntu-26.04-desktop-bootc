# Review Build
Use this skill to perform a safety check before applying changes to the `Containerfile` or `shared/` scripts.

## Steps
1. Read the modified file.
2. Check if the change violates constraints defined in `AGENTS.md` (e.g., `/var` management, symlink paths, `apt` usage in the system layer).
3. Suggest a test build command (`just build`) if appropriate.
