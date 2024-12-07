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
    "id": 666,
    "date": "1993-08-10 14:23:11",
    "sender": "varg@mayhem.no",
    "chat": "Black Metal Circle",
    "recipients": [
      "euronymous@deathlike.no",
      "dead@mayhem.no"
    ],
    "message": "Meeting at the cabin tomorrow at 10pm",
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
  "--name:Fenriz": [
    {
      "name": "Fenriz Nagell",
      "phones": ["+47 555 666 777"],
      "emails": ["fenriz@darkthrone.no"]
    }
  ],
  "--phone:123": [
    {
      "name": "Abbath Doom Occulta",
      "phones": ["+47 123 666 789"],
      "emails": ["abbath@immortal.no"]
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
FROM: Ihsahn (IN Emperor Rehearsals)
https://www.youtube.com/watch?v=Kze6ULtcIlE

FROM: Gaahl (WITH King ov Hell)
https://soundcloud.com/user-425444345/mayhem-pagan-fears
```

Notes:
- Requires imsg-grep and contact-lookup tools
- Searches messages since 2024-01-01
- Resolves contact names via Contacts.app

TO BE MADE FLEXIBLE

# decode

Decodes archived NSAttributedString from stdin. Used for decoding chat.db attributedBody.

This is a debug tool.

## Usage
```sh
# From pasteboard
pbpaste | ./decode

# From Messages.app database
sqlite3 chat.db "SELECT hex(attributedBody) FROM message WHERE ROWID = 126885;" | ./decode --hex
```

Flags:
  --hex    Input is hex encoded rather than raw binary

Note: Used by imsg-grep internally to decode iMessage attributed text content.
