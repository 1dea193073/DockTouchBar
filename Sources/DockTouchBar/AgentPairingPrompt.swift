import Foundation

/// “配对智能体”页里给用户复制的提示词：用户把它交给任何有自主能力的智能体（Claude Code、Codex、WorkBuddy、豆包、千问……），
/// 由智能体自己去查它所在软件怎么挂 hook / 写指令，完成接入、验证并登记。提示词里的路径都是这台电脑上的真实路径。
enum AgentPairingPrompt {
    static func text() -> String {
        let script = AgentHookInstaller.scriptURL.path
        // 简体/繁体中文界面给中文提示词，其余语言给英文（智能体都读得懂）。
        return L10n.isChinese ? chinese(script: script) : english(script: script)
    }

    private static func chinese(script: String) -> String {
        """
        你是一个 AI 智能体。请把你自己接入我 Mac 上的「\(AppInfo.name)」：你「正在工作」时，我的 Touch Bar 上你所在 App 的图标会显示字符雨，你做完时显示 OK。

        【三条红线，先读完再动手】
        1. 不伪造。不要伪装成别的 App，不要编译或启动“包装 App”，不要冒充 bundle id，不要自己手写登记文件，不要编造验证结果。验证通过与否只看 \(AppInfo.name) 自己回复的 PASS 或 FAIL。
        2. 卡住就停。任何一步的结果和下面写的“期望”不一样，立刻停下来，把命令和输出原样贴给我，然后等我回复。不要自己想办法绕过去。
        3. 只加不删。改任何配置前先备份；不删除、不修改我已有的配置；文件格式不合法就不要动它，告诉我。

        【你只需要这三条命令】（路径已经是真实的，原样用）
        "\(script)" --verify <你的id> < /dev/null
        "\(script)" --register <你的id> "<显示名>" <hook、instructions 或 passive> "<一句话说明>" <你改过的文件的绝对路径…> < /dev/null
        "\(script)" <事件> <你的id> < /dev/null
        - 你的id：小写字母、数字、短横线，用你自己的产品名（例如 workbuddy）。
        - 命令末尾一定要加 < /dev/null。事件命令会立刻返回、从不报错；\(AppInfo.name) 没开时什么也不做。
        - 你的命令跑在沙箱、容器、XPC 服务里都没关系，\(AppInfo.name) 会自己找到你所在的 App，你不需要为此改装任何东西。

        【事件只有这 5 个】
        UserPromptSubmit —— 用户交给你任务、你开始工作时
        PostToolUse —— 你每完成一步（跑完一个命令或工具）之后。超过 3 分钟没有任何事件，动画会被当作已中断而停掉
        Stop —— 你做完这一轮、停下来等用户时。每个任务都要以 Stop 收尾，哪怕出错了
        Interrupt —— 用户中途打断你时
        SessionEnd —— 会话关闭时

        【步骤，按顺序做，每步看期望】
        1. 自检：运行 "\(script)" --check <你的id> < /dev/null。期望：第一行以 OK 开头，并有 host_app=… 和 watch=… 两行。
           若是 NOT_RUNNING：请我先打开 \(AppInfo.name)，然后停下等我。若是 host_app=NOT_FOUND：停下并汇报（红线 2）。
           若 watch=builtin：这个软件的工作状态 \(AppInfo.name) 自己就能看到，你什么都不用配置：直接跳到第 4 步，登记（第 5 步）时方法写 passive、不用列文件。不要修改任何文件，不要写规则。
           若 watch=none：继续第 2 步。
        2. （只有 watch=none 才做）选方案：查你所在软件的官方文档，它支持 hook 或生命周期回调（并且你能确认配置文件的位置、格式、事件名）就用方案 A，否则用方案 B。不要凭记忆写；拿不准就选 B。
        3. （只有 watch=none 才做）接入。
           方案 A：把上面 5 个事件映射到软件里最接近的事件，让它们执行 "\(script)" <事件> <你的id> < /dev/null。如果配置里已经有调用这个脚本的旧条目（以前的版本留下的），改成带你的 id 的写法，不要重复添加。如果软件要求我审核或信任新增的 hook，告诉我具体在哪里点什么，不要绕过，不要伪造信任。
           方案 B：把下面这段规则原样加进你的长期指令（AGENTS.md、规则、记忆、自定义指令之类），告诉我加在了哪个文件：
           “每次用户交给我任务，先运行 "\(script)" UserPromptSubmit <你的id> < /dev/null。之后每完成一个命令或工具，运行 "\(script)" PostToolUse <你的id> < /dev/null。回复完用户、结束任务前，运行 "\(script)" Stop <你的id> < /dev/null（出错了也要运行）。”
           （把规则里的 <你的id> 换成你真实的 id。）方案 B 靠你每次自觉照做，比 hook 靠不住，请如实告诉我。
        4. 验证：运行 "\(script)" --verify <你的id> < /dev/null。期望：以 PASS 开头，我的 Touch Bar 上你所在 App 的图标出现字符雨、随后显示 OK。若是 FAIL，或没有 PASS：停下并汇报（红线 2）。
        5. 登记：运行 "\(script)" --register <你的id> "<显示名>" <hook、instructions 或 passive> "<一句话说明做了什么>" <你改过的所有文件的绝对路径…> < /dev/null。期望：以 OK 开头。登记只有 --verify 通过后才会被接受。

        【最后，按这个模板汇报，不要加别的】
        结果：成功 / 卡住了
        方案：A（hook）/ B（长期指令）/ P（passive，\(AppInfo.name) 直接监视，没改任何东西）
        改过的文件：（绝对路径，没有就写“无”）
        映射的事件：（方案 A 才写）
        --verify 的原始输出：（原样贴）
        需要我手动做的：（没有就写“无”）
        卡住的话，写明卡在第几步、命令和原始输出。
        """
    }

    private static func english(script: String) -> String {
        """
        You are an AI agent. Please connect yourself to "\(AppInfo.name)" on my Mac: while you work, the icon of the app you run in on my Touch Bar shows falling digits, and when you finish it shows OK.

        [Three red lines — read them before you start]
        1. Don't fake anything. Don't pretend to be another app, don't build or launch a "wrapper app", don't spoof a bundle id, don't hand-write the registration file, don't invent verification results. Whether verification passed is decided only by the PASS or FAIL that \(AppInfo.name) itself replies.
        2. If stuck, stop. If any step's result differs from the "expected" below, stop right away, paste the command and its output to me as is, and wait for my reply. Don't try to work around it.
        3. Only add, never remove. Back up any config before changing it; don't delete or modify my existing settings; if a file isn't valid, leave it alone and tell me.

        [You only need these three commands] (the path is real; use it as is)
        "\(script)" --verify <your-id> < /dev/null
        "\(script)" --register <your-id> "<display name>" <hook, instructions or passive> "<one-line note>" <absolute paths of the files you changed…> < /dev/null
        "\(script)" <event> <your-id> < /dev/null
        - your-id: lowercase letters, digits and dashes only; use your own product name (e.g. workbuddy).
        - Always end the command with < /dev/null. Event commands return immediately, never fail, and do nothing when \(AppInfo.name) isn't running.
        - It doesn't matter if your commands run in a sandbox, a container or an XPC service: \(AppInfo.name) finds your app by itself, and you don't need to rig anything for that.

        [Only these 5 events]
        UserPromptSubmit — the user hands you a task and you start working
        PostToolUse — after each step you finish (a command or tool call). With no events for 3 minutes the animation is treated as interrupted and stops
        Stop — you finish this turn and wait for the user. Every task must end with Stop, even when it failed
        Interrupt — the user interrupts you
        SessionEnd — the session closes

        [Steps — do them in order and check each expectation]
        1. Self-check: run "\(script)" --check <your-id> < /dev/null. Expected: the first line starts with OK, followed by a host_app=… line and a watch=… line.
           NOT_RUNNING: ask me to open \(AppInfo.name), then stop and wait. host_app=NOT_FOUND: stop and report (red line 2).
           watch=builtin: \(AppInfo.name) can see this app's working state by itself and you configure nothing: jump to step 4, and when registering (step 5) use method passive and list no files. Don't modify any file or write any rule.
           watch=none: continue with step 2.
        2. (Only when watch=none) Pick a method: check the official docs of the app you run in. If it supports hooks or lifecycle callbacks (and you can confirm the config file location, format and event names), use Option A; otherwise Option B. Don't write from memory; if unsure, pick B.
        3. (Only when watch=none) Connect.
           Option A: map the 5 events above to the closest events in your app and make them run "\(script)" <event> <your-id> < /dev/null. If the config already has older entries that call this script (left by earlier versions), update them to the form with your id instead of adding duplicates. If your app requires me to review or trust new hooks, tell me exactly where to click; don't bypass it or fake trust.
           Option B: add this rule as is to your long-term instructions (AGENTS.md, rules, memory, custom instructions…) and tell me which file:
           "Whenever the user gives me a task, first run "\(script)" UserPromptSubmit <your-id> < /dev/null. After each command or tool call, run "\(script)" PostToolUse <your-id> < /dev/null. After replying to the user, before the task ends, run "\(script)" Stop <your-id> < /dev/null (also when it failed)."
           (Replace <your-id> in the rule with your real id.) Option B depends on you following it every time, so it is less reliable than hooks; please tell me honestly.
        4. Verify: run "\(script)" --verify <your-id> < /dev/null. Expected: it starts with PASS, and on my Touch Bar the icon of your app shows falling digits, then OK. If it says FAIL or doesn't say PASS: stop and report (red line 2).
        5. Register: run "\(script)" --register <your-id> "<display name>" <hook, instructions or passive> "<one line on what you did>" <absolute paths of every file you changed…> < /dev/null. Expected: it starts with OK. Registration is only accepted after --verify passed.

        [Finally, report with this template and add nothing else]
        Result: success / stuck
        Option: A (hook) / B (long-term instructions) / P (passive: \(AppInfo.name) watches it directly, nothing changed)
        Files changed: (absolute paths; "none" if none)
        Events mapped: (Option A only)
        Raw output of --verify: (paste as is)
        Manual steps for me: ("none" if none)
        If stuck: say which step, and paste the command and its raw output.
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
