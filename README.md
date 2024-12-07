# iMessage & Contacts CLI Tools

Scripts require MacOS permissions for Messages.app and Contacts.app access.

## Install
```sh
make
```

# imsg-grep

Query Messages.app database with pattern matching and filters.

```sh
imsg-grep [flags] pattern

Flags:
  --since DATE    Show messages after DATE (ISO format)
  --to PATTERN    Match chat name or participants
  --from PATTERN  Match sender or chat name
  --with PATTERN  Match sender, chat name, or participants
  --sender REGEX  Match just the sender
  --chat REGEX    Match just the chat name
  --raw          Use SQL LIKE instead of regex pattern
```

A bit overkill but ¯\\\_(ツ)\_/¯

## Example Output
```json
[
  {
    "id": 123456,
    "date": "2024-01-15 14:23:11",
    "sender": "alice@example.com",
    "chat": "Team Chat",
    "recipients": [
      "bob@example.com",
      "carol@example.com"
    ],
    "message": "Meeting tomorrow at 10am",
    "has_attachments": false
  }
]
```

# contact-lookup

Query MacOS Contacts.app with pattern matching.

## Usage
```sh
contact-lookup [--field value]...

Fields:
  --name VALUE   Match contact name
  --phone VALUE  Match phone number (digits only)
  --email VALUE  Match email address
```

## Example Output
```json
{
  "--name:John": [
    {
      "name": "John Smith",
      "phones": ["+1 (555) 123-4567"],
      "emails": ["john.smith@example.com"]
    }
  ],
  "--phone:123": [
    {
      "name": "Jane Doe",
      "phones": ["+1 (123) 555-7890"],
      "emails": ["jane@example.com"]
    }
  ]
}
```

Notes:
- Phone matching ignores formatting/special chars
- Multiple search criteria combine with AND logic
- Queries are case insensitive

# tubes

Display Youtube/Soundcloud URLs from iMessage history.

## Usage
```sh
./tubes
```

## Example Output
```
FROM: John Smith (IN Music Share Group)
https://www.youtube.com/watch?v=dQw4w9WgXcQ

FROM: Alice Jones (WITH Bob Wilson)
https://soundcloud.com/artist/track-name
```

Notes:
- Requires imsg-grep and contact-lookup tools
- Searches messages since 2024-01-01
- Resolves contact names via Contacts.app

TO BE MADE FLEXIBLE
