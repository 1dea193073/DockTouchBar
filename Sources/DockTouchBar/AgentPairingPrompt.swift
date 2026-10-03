import Foundation

/// “配对智能体”页里给用户复制的提示词：用户把它交给任何有自主能力的智能体（Claude Code、Codex、WorkBuddy、豆包、千问……），
/// 由智能体自己去查它所在软件怎么挂 hook / 写指令，完成接入、验证并登记。提示词里的路径都是这台电脑上的真实路径。
enum AgentPairingPrompt {
    static func text() -> String {
        let script = AgentHookInstaller.scriptURL.path
        let log = AgentRegistry.logURL.path
        let agents = AgentRegistry.directory.path
        // 简体/繁体中文界面给中文提示词，其余语言给英文（智能体都读得懂）。
        return L10n.isChinese ? chinese(script: script, log: log, agents: agents) : english(script: script, log: log, agents: agents)
    }

    private static func chinese(script: String, log: String, agents: String) -> String {
        """
        你是一个 AI 智能体。我想让你和我 Mac 上的「\(AppInfo.name)」配对：它会在我的 Touch Bar 上、你所在 App 的图标上，在你「正在工作」时显示字符雨动画，你做完时显示 OK。请你自己完成接入，每一步都告诉我你做了什么。

        【你要调用的东西】
        脚本：\(script)
        用法：\"\(script)\" <事件> <你的id> <会话id> < /dev/null
        - 你的id：只能用小写字母、数字、短横线，用你自己的产品名（例如 workbuddy）。
        - 会话id：同一次任务的所有事件必须用同一个。任务开始时生成一个短的随机串（例如 $(date +%s)-$RANDOM），这次任务里一直复用。
        - 命令末尾一定要加 < /dev/null。脚本会立刻返回，从不报错；\(AppInfo.name) 没开时它什么也不做。

        【只用这 5 个事件】
        UserPromptSubmit —— 用户交给你任务、你开始工作时
        PostToolUse —— 你每完成一步（跑完一个命令/工具）之后。可选；超过 10 分钟没有任何事件，会被当作已中断
        Stop —— 你做完这一轮、停下来等用户时
        Interrupt —— 用户中途打断你时
        SessionEnd —— 会话关闭时

        【方案 A（优先）：用你所在软件自己的 hook / 生命周期回调】
        1. 查你所在软件的官方文档，确认它是否支持 hook 或事件回调（配置文件位置、格式、事件名）。不要凭记忆写。
        2. 改任何配置前先备份。只增加，不删除、不修改我已有的 hook 和配置；文件如果不是合法格式，不要动它，告诉我。
        3. 把上面 5 个事件映射到你软件里最接近的事件，让它们执行上面的脚本命令。
        4. 如果你的软件要求我审核或信任新增的 hook，告诉我具体要在哪里点什么。不要绕过，不要伪造信任。

        【方案 B：你的软件没有 hook 时】
        把下面这条规则加进你的长期指令里（例如 AGENTS.md、规则、记忆、自定义指令），并告诉我加在了哪里：
        “每次开始处理用户的任务时，先运行 \"\(script)\" UserPromptSubmit <你的id> <会话id> < /dev/null；回复完用户、任务结束前，运行 \"\(script)\" Stop <你的id> <会话id> < /dev/null。”
        这种方式比 hook 靠不住（取决于你每次是否照做），请如实告诉我。

        【验证】
        1. 运行 \"\(script)\" UserPromptSubmit <你的id> test-1 < /dev/null，等 2 秒，再运行 \"\(script)\" Stop <你的id> test-1 < /dev/null。
        2. 查看 \(log) 的最后几行：应该有 UserPromptSubmit 和 Stop，agent=<你的id>，并且 app= 是你所在 App 的 bundle id。如果 app=-，说明没找到你所在的 App，请如实告诉我，不要说成功。
        3. 这时我的 Touch Bar 上，你所在 App 的图标应该出现过动画，然后显示 OK。

        【登记】
        验证通过后，把下面的 JSON 写到 \(agents)/<你的id>.json（目录不存在就创建）。文件名必须和 id 一致：
        {"id":"<你的id>","name":"<显示名>","method":"hook 或 instructions","files":["你改过的所有文件的绝对路径"],"notes":"一句话说明做了什么"}

        【最后】
        用一小段话告诉我：你改了哪些文件、映射了哪些事件、有没有需要我手动做的步骤、验证结果。遇到任何问题请停下来告诉我，不要自己绕过限制。
        """
    }

    private static func english(script: String, log: String, agents: String) -> String {
        """
        You are an AI agent. I want you to pair with "\(AppInfo.name)" on my Mac: it shows a falling-digits animation on my Touch Bar, on the icon of the app you run in, while you work, and an OK when you finish. Please do the integration yourself and tell me what you did at every step.

        [What you call]
        Script: \(script)
        Usage: "\(script)" <event> <your-id> <session-id> < /dev/null
        - your-id: lowercase letters, digits and dashes only; use your own product name (e.g. workbuddy).
        - session-id: every event of the same task must use the same one. At the start of a task generate a short random string (e.g. $(date +%s)-$RANDOM) and reuse it for that task.
        - Always end the command with < /dev/null. The script returns immediately and never fails; it does nothing when \(AppInfo.name) isn't running.

        [Use only these 5 events]
        UserPromptSubmit — the user hands you a task and you start working
        PostToolUse — after each step you finish (a command or tool call). Optional; with no events for 10 minutes the task is treated as interrupted
        Stop — you finish this turn and wait for the user
        Interrupt — the user interrupts you
        SessionEnd — the session closes

        [Option A (preferred): use your host app's own hooks / lifecycle callbacks]
        1. Check the official docs of the app you run in for hooks or event callbacks (config file location, format, event names). Don't write from memory.
        2. Back up any config before changing it. Only add; never delete or modify my existing hooks or settings. If a file isn't valid, leave it alone and tell me.
        3. Map the 5 events above to the closest events in your app and make them run the script command above.
        4. If your app requires me to review or trust new hooks, tell me exactly where to click. Do not bypass it or fake trust.

        [Option B: if your app has no hooks]
        Add this rule to your long-term instructions (e.g. AGENTS.md, rules, memory, custom instructions) and tell me where you put it:
        "When you start working on a user's task, first run "\(script)" UserPromptSubmit <your-id> <session-id> < /dev/null; after replying to the user and before the task ends, run "\(script)" Stop <your-id> <session-id> < /dev/null."
        This is less reliable than hooks (it depends on you following it every time); please tell me honestly.

        [Verify]
        1. Run "\(script)" UserPromptSubmit <your-id> test-1 < /dev/null, wait 2 seconds, then run "\(script)" Stop <your-id> test-1 < /dev/null.
        2. Read the last lines of \(log): you should see UserPromptSubmit and Stop with agent=<your-id>, and app= should be the bundle id of the app you run in. If app=- the app wasn't found; tell me honestly instead of claiming success.
        3. At that point the icon of your app on my Touch Bar should have animated and then shown OK.

        [Register]
        After verification passes, write this JSON to \(agents)/<your-id>.json (create the directory if needed). The file name must match the id:
        {"id":"<your-id>","name":"<display name>","method":"hook or instructions","files":["absolute paths of every file you changed"],"notes":"one sentence on what you did"}

        [Finally]
        Tell me in a short paragraph: which files you changed, which events you mapped, any manual steps I need to do, and the verification result. If anything goes wrong, stop and tell me; don't work around restrictions.
        """
    }

    /// 取消配对时交给智能体的提示词：让它自己还原当初改过的文件，并删除登记。
    static func unpairText(_ agent: PairedAgent) -> String {
        let registration = AgentRegistry.directory.appendingPathComponent("\(agent.id).json").path
        if L10n.isChinese {
            return """
                请撤销你之前为「\(AppInfo.name)」做的配对：把你当初改过的文件里，调用 \(AgentHookInstaller.scriptURL.path) 的那些 hook 或规则删掉，只删这些，保留我其他的配置（改之前先备份）。登记里记录的文件：\(agent.files.joined(separator: "、"))。做完后删除 \(registration)，并告诉我改了什么。
                """
        }
        return """
            Please undo the pairing you set up for "\(AppInfo.name)": remove the hooks or rules that call \(AgentHookInstaller.scriptURL.path) from the files you changed, and only those, keeping my other settings (back up first). Files recorded at registration: \(agent.files.joined(separator: ", ")). Then delete \(registration) and tell me what you changed.
            """
    }
}
