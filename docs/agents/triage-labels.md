# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those
roles to the actual strings used in this repo's issue tracker.

Because issues are local markdown files, these strings are the allowed values of
the `Status:` line in each issue file — not labels in a web UI.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), write the
corresponding string into the issue's `Status:` line.

Edit the right-hand column to match whatever vocabulary you actually use.
