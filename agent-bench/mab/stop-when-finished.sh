#!/bin/sh
# A Claude Code PostToolUse hook for the MedAgentBench tools arm: when `finish` has written the
# answers ("Finished."), the task is over. Without it the agent is asked once more, with the whole
# conversation, only to say that it is done.
if grep -q 'Finished\.'; then
  printf '{"continue": false, "stopReason": "the task is finished"}\n'
fi
