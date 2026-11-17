#!/bin/sh
# A Claude Code PostToolUse hook for the tables arm: when `./answer` has written the answer and
# found nothing to look at again (its last line, "done: …"), the session is over. Without it the
# agent is asked once more, with the whole conversation, only to say that it is done.
if grep -q 'done: the answer is written'; then
  printf '{"continue": false, "stopReason": "the answer is written"}\n'
fi
