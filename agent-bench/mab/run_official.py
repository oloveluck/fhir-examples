#!/usr/bin/env python3
"""MedAgentBench's own protocol, against a chosen FHIR server: the model answers each turn with one
`GET url`, `POST url\\n<json>` or `FINISH([...])` line and nothing else (no tools of its own); a GET
is sent to the server, a POST is accepted without being sent; at most 8 rounds. This is the
benchmark's MedAgentBench.start_sample (src/server/tasks/medagentbench/__init__.py) with the model
behind `claude -p` (the conversation resumed each round). Run against HAPI and against our server,
the same model and tasks show whether the server is a drop-in replacement.

usage: run_official.py SERVER_BASE OUT_DIR [--model M] [--per-task N | --ids …] [--parallel K]
writes per task: history.json (role/content) and answer.json; grade with grade_official.py.
"""
import argparse, concurrent.futures as cf, json, os, pathlib, subprocess, tempfile
import urllib.request

PROMPT = """You are an expert in using FHIR functions to assist medical professionals. You are given a question and a set of possible functions. Based on the question, you will need to make one or more function/tool calls to achieve the purpose.

1. If you decide to invoke a GET function, you MUST put it in the format of
GET url?param_name1=param_value1&param_name2=param_value2...

2. If you decide to invoke a POST function, you MUST put it in the format of
POST url
[your payload data in JSON format]

3. If you have got answers for all the questions and finished all the requested tasks, you MUST call to finish the conversation in the format of (make sure the list is JSON loadable.)
FINISH([answer1, answer2, ...])

Your response must be in the format of one of the three cases, and you can call only one function each time. You SHOULD NOT include any other text in the response.

Here is a list of functions in JSON format that you can invoke. Note that you should use {api_base} as the api_base.
{functions}

Context: {context}
Question: {question}"""

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def send_get(url):
    """As the benchmark's send_get_request: the body (text unless the type is exactly application/json)."""
    try:
        with opener.open(url, timeout=120) as r:
            body = r.read().decode()
            if r.headers.get("Content-Type") == "application/json":
                return {"data": json.loads(body)}
            return {"data": body}
    except Exception as e:
        return {"error": str(e)}


def ask(text, session, model, work):
    cmd = ["claude", "-p", text, "--model", model, "--output-format", "json", "--max-turns", "1", "--tools", ""]
    if session:
        cmd += ["--resume", session]
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"}
    p = subprocess.run(cmd, cwd=work, env=env, capture_output=True, text=True, timeout=600)
    d = json.loads(p.stdout)
    return d["result"], d["session_id"], d.get("total_cost_usd") or 0


def run_task(t, base, funcs, model, out):
    work = out / t["id"]; work.mkdir(parents=True, exist_ok=True)
    history, session, cost = [], None, 0.0
    msg = PROMPT.format(api_base=base, functions=json.dumps(funcs), context=t["context"], question=t["instruction"])
    history.append({"role": "user", "content": msg})
    result, status = None, "TASK_LIMIT_REACHED"
    for _ in range(8):
        reply, session, c = ask(msg, session, model, work); cost += c
        history.append({"role": "agent", "content": reply})
        r = reply.strip().replace("```tool_code", "").replace("```", "").strip()
        if r.startswith("GET"):
            g = send_get(r[3:].strip() + "&_format=json")
            msg = (f"Here is the response from the GET request:\n{g['data']}. Please call FINISH if you have got answers for all the questions and finished all the requested tasks"
                   if "data" in g else f"Error in sending the GET request: {g['error']}")
        elif r.startswith("POST"):
            try:
                json.loads("\n".join(r.split("\n")[1:]))
                msg = "POST request accepted and executed successfully. Please call FINISH if you have got answers for all the questions and finished all the requested tasks"
            except Exception:
                msg = "Invalid POST request"
        elif r.startswith("FINISH("):
            result, status = r[len("FINISH("):-1], "COMPLETED"
            break
        else:
            status = "AGENT_INVALID_ACTION"
            break
        history.append({"role": "user", "content": msg})
    (work / "history.json").write_text(json.dumps(history, indent=1))
    (work / "answer.json").write_text(json.dumps({"finish": result, "status": status, "cost_usd": cost}))
    print(f"{t['id']:12} {status:20} ${cost:.3f}", flush=True)
    return cost


def first_of_each(tasks, n):
    """The first n tasks of each kind (task1 … task10), in file order."""
    count, kept = {}, []
    for t in tasks:
        kind = t["id"].split("_")[0]
        count[kind] = count.get(kind, 0) + 1
        if count[kind] <= n:
            kept.append(t)
    return kept


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base"); ap.add_argument("out")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--per-task", type=int, default=0)
    ap.add_argument("--ids", default="")
    ap.add_argument("--parallel", type=int, default=4)
    a = ap.parse_args()
    tasks = json.load(open(os.environ["MAB_TASKS"]))
    funcs = json.load(open(os.environ["MAB_FUNCS"]))
    if a.ids:
        tasks = [t for t in tasks if t["id"] in set(a.ids.split(","))]
    elif a.per_task:
        tasks = first_of_each(tasks, a.per_task)
    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    (out / "run.json").write_text(json.dumps({"protocol": "official", "base": a.base, "model": a.model}))
    with cf.ThreadPoolExecutor(a.parallel) as ex:
        costs = list(ex.map(lambda t: run_task(t, a.base, funcs, a.model, out), tasks))
    print(f"total ${sum(costs):.2f}")


if __name__ == "__main__":
    main()
