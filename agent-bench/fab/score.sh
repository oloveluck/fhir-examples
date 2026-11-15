#!/bin/bash
# Score a run with FHIR-AgentBench's own evaluation_metrics.py, unmodified: the judge prompts, the
# null-answer rule and the retrieval precision/recall are theirs; only the model behind litellm is
# Claude (shim/litellm). usage: score.sh RUN_DIR [JUDGE_MODEL]
#   FAB_REPO: a checkout of github.com/glee4810/FHIR-AgentBench
set -e
run=$(cd "$1" && pwd); judge=${2:-sonnet}
here=$(cd "$(dirname "$0")" && pwd)
cd "$FAB_REPO"
PYTHONPATH="$here/shim:$FAB_REPO" OPENAI_API_KEY=unused FAB_JUDGE_MODEL="$judge" \
  python3 evaluation_metrics.py --input "$run/agent_results.json" --output_dir "$run/eval" \
  --model "$judge" --num_processes 4
