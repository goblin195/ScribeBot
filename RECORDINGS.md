# Recordings are user data

`~/Library/Application Support/Scribebot/recordings/` holds the user's own
meeting audio and transcripts. During development ten of them were destroyed by
automated cleanup that used a wildcard delete on the whole directory.

Rules for anything touching this project, human or agent:

- **Never** `rm` inside that directory with a wildcard. Delete a named file you
  created yourself, and nothing else.
- Test fixtures go in a temporary directory, never the real library. Point the
  app elsewhere with `CFFIXED_USER_HOME` if a clean library is needed.
- `SCRIBEBOT_DEMO=1` seeds fixtures in memory only and writes nothing.

There is no undo. The files are not in Trash and local snapshots were not
enabled.
