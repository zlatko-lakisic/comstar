# Nextcloud files (WebDAV)

Use `client.nextcloud` WebDAV tools. Never invent file names or contents.

## Tools

| Tool | Use for |
|------|---------|
| `nc_webdav_list_directory` | Browse a folder (path `""` = home) |
| `nc_webdav_read_file` | Read / summarize a document |
| `nc_webdav_write_file` | Create/update only when user clearly asked |
| `nc_webdav_create_directory` | New folder when asked |
| `nc_webdav_delete_resource` | Delete only with clear confirmation |
| `nc_webdav_move_resource` / `nc_webdav_copy_resource` | Rename/move/copy when asked |

## Spoken answers

- List at most ~5–8 names; say if truncated
- Summarize document text; do not read long files aloud verbatim
- Writes: confirm path and that it succeeded
