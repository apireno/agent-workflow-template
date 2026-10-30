"""Shared by record-approval.sh and check-authorization.sh: find a Claude Code session transcript,
tell whether that session ran in a CTO home, and find the CEO's words in its human messages.

    python3 -I _approval_transcript.py locate <session-id>           -> transcript path, or exit 1
    python3 -I _approval_transcript.py verify <session-id> <words>   -> JSON {transcript, cwd,
                                                                       cto_home, found, uuid, date}

A CTO home is a repo whose name is agent-workflow-template or ends in -cto, or that carries
.cto/projects.yaml. Human messages are the user turns a person typed: not tool results, not
skill or meta injections, not sidechains, not compaction summaries. Matching is exact after
whitespace is collapsed and curly quotes are straightened, so a quote has to be the CEO's own
words; a paraphrase does not match.
"""
import datetime, glob, json, os, re, sys

QUOTES = str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"'})


def norm(s):
    return re.sub(r"\s+", " ", (s or "").translate(QUOTES)).strip()


def projects_dir():
    return os.environ.get("CLAUDE_PROJECTS_DIR") or os.path.expanduser("~/.claude/projects")


def locate(sid):
    if not re.fullmatch(r"[A-Za-z0-9-]+", sid or ""):
        return None
    hits = glob.glob(os.path.join(projects_dir(), "*", sid + ".jsonl"))
    return hits[0] if hits else None


def repo_root(path):
    p = os.path.abspath(path or "/")
    while p != "/":
        if os.path.exists(os.path.join(p, ".git")):
            return p
        p = os.path.dirname(p)
    return os.path.abspath(path or "/")


def is_cto_home(path):
    root = repo_root(path)
    name = os.path.basename(root)
    return name == "agent-workflow-template" or name.endswith("-cto") or \
        os.path.isfile(os.path.join(root, ".cto", "projects.yaml"))


def human_texts(entry):
    if entry.get("type") != "user" or entry.get("isMeta") or entry.get("isSidechain") \
            or entry.get("isCompactSummary") or entry.get("toolUseResult") is not None:
        return []
    c = (entry.get("message") or {}).get("content")
    if isinstance(c, str):
        texts = [c]
    elif isinstance(c, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return []
        texts = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
    else:
        return []
    return [re.sub(r"<system-reminder>.*?</system-reminder>", " ", t, flags=re.S) for t in texts]


def verify(sid, words):
    out = {"transcript": locate(sid), "cwd": None, "cto_home": False, "found": False, "uuid": None, "date": None}
    if not out["transcript"]:
        return out
    want = norm(words)
    for line in open(out["transcript"], errors="replace"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if out["cwd"] is None and e.get("cwd"):
            out["cwd"] = e["cwd"]
            out["cto_home"] = is_cto_home(e["cwd"])
        if want and not out["found"] and any(want in norm(t) for t in human_texts(e)):
            out["found"], out["uuid"] = True, e.get("uuid")
            ts = e.get("timestamp")
            if ts:
                try:
                    out["date"] = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().date().isoformat()
                except ValueError:
                    pass
    return out


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "locate" and len(sys.argv) == 3:
        t = locate(sys.argv[2])
        print(t or "")
        sys.exit(0 if t else 1)
    if cmd == "verify" and len(sys.argv) == 4:
        print(json.dumps(verify(sys.argv[2], sys.argv[3])))
        sys.exit(0)
    sys.stderr.write(__doc__)
    sys.exit(2)
