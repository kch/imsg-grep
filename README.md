# imsg-grep

Search and filter iMessage history from command line.

## Features

Search iMessage history with regex patterns, date ranges, and participant filters. Extract links and media files. Output text or JSON.

- Contact filtering (sender/recipient matching)
- Date range queries with relative formats
- Link extraction (YouTube, Twitter, etc.)
- File and image attachment search
- Inline terminal images
- Boolean expressions

## Requirements

macOS, ruby 3.4+, SQLite.

iTerm or Ghostty (or other kitty) for image support. 

## Installing

```
gem install imsg-grep
```

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

See [`--help`](doc/HELP) for more.

## Examples

```bash
# Basic search
imsg-grep "hello"

# From specific contact since date
imsg-grep -f Alice -d 2024-01-01 "meeting"

# YouTube links in group chats
imsg-grep -c -Y

# Extract usernames from mentions
imsg-grep -o '@(\w+)' '@\w+'

# JSON output
imsg-grep -j -f Bob -d 1w
```

## Date Formats

- ISO8601: `2024-12-30`, `2024-12-30T12:45Z`
- Relative: `1w` (1 week), `30min`, `3a` (3am today)

## Patterns

Regular expressions by default. Use `-q` for literal matching, `-i/-I` for case control.
