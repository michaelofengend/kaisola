# Backlog media

Reference screenshots and videos for items in [`../BACKLOG.md`](../BACKLOG.md).

## How to add media to a backlog item

1. Drop the file in this folder (or a subfolder per item for multiple files).
2. Name it after the item, kebab-case, with a date if helpful:
   `mesh-card-overlap-2026-07-13.png`, `session-close-flow.mov`.
3. Link it from the backlog item line:

```markdown
- [ ] Fix narrow Mesh cards so labels never overlap response text.
      ![overlap](backlog-media/mesh-card-overlap-2026-07-13.png)
      [screen recording](backlog-media/mesh-card-overlap.mov)
```

Images render inline in most Markdown viewers; videos (`.mov`, `.mp4`, `.gif`)
are plain links — GIFs render inline if you want a moving preview.

Media stays in git so items keep their evidence after they're checked off.
