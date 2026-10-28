# usage: python3 -I report.py <folder of run logs>
import json
import glob
import os
import sys

S = sys.argv[1].rstrip("/") + "/"
rows = []
calls = []
for f in sorted(glob.glob(S + "*.jsonl")):
    arm, qid = os.path.basename(f)[:-6].split("-")
    res = None
    pending = {}
    for line in open(f):
        d = json.loads(line)
        if d.get("type") == "result":
            res = d
        m = d.get("message", {})
        c = m.get("content")
        if d.get("type") == "assistant" and isinstance(c, list):
            for b in c:
                if b.get("type") == "tool_use":
                    pending[b["id"]] = (b["name"], json.dumps(b["input"])[:110])
        if d.get("type") == "user" and isinstance(c, list):
            for b in c:
                if b.get("type") == "tool_result":
                    name, inp = pending.get(b["tool_use_id"], ("?", ""))
                    cc = b.get("content")
                    txt = img = 0
                    if isinstance(cc, list):
                        for x in cc:
                            if x.get("type") == "text":
                                txt += len(x["text"])
                            else:
                                img += 1
                    else:
                        txt = len(cc or "")
                    calls.append((arm, qid, name, inp, txt, img, b.get("is_error")))
    if not res:
        rows.append((arm, qid, None))
        continue
    u = res["usage"]
    rows.append(
        (
            arm,
            qid,
            dict(
                ans=res.get("result", "").replace("\n", " | "),
                turns=res["num_turns"],
                cost=res["total_cost_usd"],
                inp=u["input_tokens"],
                cw=u["cache_creation_input_tokens"],
                cr=u["cache_read_input_tokens"],
                out=u["output_tokens"],
                sec=res["duration_ms"] / 1000,
            ),
        )
    )
print("arm qid  turns cost$   fresh cacheW cacheR out  sec  answer")
for arm, qid, r in sorted(rows, key=lambda x: (x[1], x[0])):
    if r:
        print(
            f"{arm} {qid} {r['turns']:>3} {r['cost']:.4f} {r['inp']:>5} {r['cw']:>6} {r['cr']:>6} {r['out']:>4} {r['sec']:>5.0f}  {r['ans'][:90]}"
        )
    else:
        print(arm, qid, "NO RESULT")
for a in "AB":
    rs = [r for ar, q, r in rows if ar == a and r]
    print(
        a,
        "total cost",
        round(sum(r["cost"] for r in rs), 4),
        "turns",
        sum(r["turns"] for r in rs),
        "cacheW",
        sum(r["cw"] for r in rs),
        "cacheR",
        sum(r["cr"] for r in rs),
        "out",
        sum(r["out"] for r in rs),
    )
print("\ncalls: arm qid tool textchars images err input")
for c in calls:
    print(*c)
