# imsg-grep

Search and filter iMessage history from command line.

## Usage

```
imsg-grep [options] [PATTERN]
```

## Key Options

**Date filtering:**
- `-d, --since DATE` - Match after date
- `-u, --until DATE` - Match before date

**Participants:**
- `-f, --from CONTACT` - Match sender
- `-t, --to CONTACT` - Match recipients
- `-w, --with CONTACT` - Match sender or recipients
- `-c, --chat [PATTERN]` - Match group chats

**Messages:**
- `-M, --message PATTERN` - Match message text
- `-s, --sent` - Only sent messages
- `-r, --received` - Only received messages
- `-n, --max NUM` - Limit results

**Links:**
- `-L, --links [PATTERN]` - Find links
- `-Y, --youtube` - Find YouTube links
- `-X, --twitter` - Find Twitter links

**Format:**
- `-l, --one-line` - Compact format
- `-j, --json` - JSON output
- `-o, --capture [EXPR]` - Extract matched parts
- `-k, --count` - Show total count

**Media:**
- `-F, --files [KIND]` - Find file attachments
- `-g, --images` - Find images with preview

## Examples

```bash
# Basic search
imsg-grep "hello"

# From specific contact since date
imsg-grep -f Alice -d 2024-01-01 "meeting"

# YouTube links in group chats
imsg-grep -c -Y

# Extract phone numbers
imsg-grep -o '\d{3}-\d{3}-\d{4}' '\d{3}-\d{3}-\d{4}'

# JSON output with counts
imsg-grep -jk -f Bob -d 1w
```

## Date Formats

- ISO8601: `2024-12-30`, `2024-12-30T12:45Z`
- Relative: `1w` (1 week), `30min`, `3a` (3am today)

## Patterns

Regular expressions by default. Use `-q` for literal matching, `-i/-I` for case control.
