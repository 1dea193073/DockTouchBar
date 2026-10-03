#!/usr/bin/env python3
"""问 Codex 的 app-server：我们装的 hook 现在是什么状态（trusted / untrusted / modified…）。只读，不改任何东西。
用法：python3 tools/check-codex-hooks.py
排查“Codex 没反应”时先跑这个：trustStatus 不是 trusted 的 hook，Codex 不会执行。"""
import json, os, select, subprocess, sys, time

CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
if not os.path.exists(CODEX):
    sys.exit("找不到 Codex：" + CODEX)
p = subprocess.Popen([CODEX, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

def send(m):
    p.stdin.write(json.dumps(m) + "\n"); p.stdin.flush()

def recv(timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        if select.select([p.stdout], [], [], 0.5)[0]:
            line = p.stdout.readline()
            if not line: return None
            try: return json.loads(line)
            except ValueError: continue
    return None

send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "dtb-check", "version": "0"}}})
recv()
send({"method": "initialized"})
send({"id": 2, "method": "hooks/list", "params": {"cwds": [os.getcwd()]}})
result = None
for _ in range(8):
    m = recv()
    if m and m.get("id") == 2:
        result = m; break
p.kill()
if not result:
    sys.exit("没有收到 hooks/list 的回复")
rows = [h for d in result["result"]["data"] for h in d["hooks"] if "DockTouchBar" in h.get("command", "")]
for h in rows:
    print(f'{h["eventName"]:18} {h["trustStatus"]:10} enabled={h["enabled"]}  {h["sourcePath"]}')
if not rows:
    print("Codex 里没有看到我们的 hook（没连接，或 Codex 还没重启）")
elif all(h["trustStatus"] == "trusted" for h in rows):
    print("OK：全部已信任")
else:
    print("还有没信任的：在终端运行 codex，输入 /hooks 审核并信任，然后 ⌘Q 重启 ChatGPT")
