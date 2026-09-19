import Testing
@testable import NotchAI

struct ClaudeTranscriptParserTests {
    @Test func userPromptStartsTask() {
        let line = #"{"type":"user","message":{"role":"user","content":"Fix the login layout\nplease"},"cwd":"/tmp/app","timestamp":"2026-09-19T09:00:00.000Z"}"#
        let entry = ClaudeTranscriptParser.parse(line)
        #expect(entry?.event == .promptSubmitted("Fix the login layout"))
        #expect(entry?.cwd == "/tmp/app")
    }

    @Test func toolUseAndResult() {
        let use = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a/LoginView.swift"}}]}}"#
        let result = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#
        #expect(ClaudeTranscriptParser.parse(use)?.event == .toolStarted("Editing LoginView.swift"))
        #expect(ClaudeTranscriptParser.parse(result)?.event == .toolFinished)
    }

    @Test func endTurnCompletes() {
        let line = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Updated the layout."}]}}"#
        #expect(ClaudeTranscriptParser.parse(line)?.event == .completed("Updated the layout."))
    }

    @Test func midTurnMessageIsAPrompt() {
        let line = #"{"type":"attachment","attachment":{"type":"queued_command","prompt":"also fix header"}}"#
        #expect(ClaudeTranscriptParser.parse(line)?.event == .promptSubmitted("also fix header"))
    }

    @Test func metaAndSidechainLinesAreIgnored() {
        #expect(ClaudeTranscriptParser.parse(#"{"type":"user","isMeta":true,"message":{"content":"x"}}"#) == nil)
        #expect(ClaudeTranscriptParser.parse(#"{"type":"assistant","isSidechain":true,"message":{"content":[]}}"#) == nil)
        #expect(ClaudeTranscriptParser.parse(#"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#) == nil)
    }

    @Test func interruptAndApiError() {
        #expect(ClaudeTranscriptParser.parse(#"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#)?.event == .interrupted)
        let error = #"{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: overloaded"}]}}"#
        #expect(ClaudeTranscriptParser.parse(error)?.event == .failed("API Error: overloaded"))
    }

    @Test func streamJSONResult() {
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.\nDetails"}"#
        let failed = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Crashed"}"#
        #expect(ClaudeTranscriptParser.parse(ok)?.event == .completed("Done."))
        #expect(ClaudeTranscriptParser.parse(failed)?.event == .failed("Crashed"))
    }

    @Test func permissionHookLines() {
        let prompt = #"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#
        let idle = #"{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#
        #expect(ClaudeTranscriptParser.permissionPrompt(fromHookLine: prompt) == "Claude needs your permission to use Bash")
        #expect(ClaudeTranscriptParser.permissionPrompt(fromHookLine: idle) == nil)
    }

    @Test func summaryShortensLongText() {
        let long = String(repeating: "a", count: 200)
        #expect(ClaudeTranscriptParser.summary(long).count == 80)
    }
}

struct CodexParserTests {
    @Test func sessionLogEvents() {
        #expect(CodexLogParser.parse(#"{"type":"session_meta","payload":{"cwd":"/tmp/app"}}"#)?.cwd == "/tmp/app")
        #expect(CodexLogParser.parse(#"{"type":"event_msg","payload":{"type":"task_started"}}"#)?.event == .thinking)
        let complete = #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"All set"}}"#
        #expect(CodexLogParser.parse(complete)?.event == .completed("All set"))
        #expect(CodexLogParser.parse(#"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#)?.event == .interrupted)
    }

    @Test func userPromptButNotEnvironmentContext() {
        let prompt = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the login layout"}]}}"#
        let context = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>…"}]}}"#
        #expect(CodexLogParser.parse(prompt)?.event == .promptSubmitted("Fix the login layout"))
        #expect(CodexLogParser.parse(context) == nil)
    }

    @Test func desktopExecScriptShowsTheCommand() {
        let call = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"npm test\"});"}}"#
        #expect(CodexLogParser.parse(call)?.event == .toolStarted("Running npm test"))
    }

    @Test func execJSONStream() {
        let command = #"{"type":"item.started","item":{"id":"1","type":"command_execution","command":"ls -la","status":"in_progress"}}"#
        #expect(CodexExecParser.parse(command)?.event == .toolStarted("Running ls -la"))
        #expect(CodexExecParser.parse(#"{"type":"item.completed","item":{"type":"agent_message","text":"Listed."}}"#)?.message == "Listed.")
        #expect(CodexExecParser.parse(#"{"type":"turn.completed","usage":{}}"#)?.event == .completed(nil))
        #expect(CodexExecParser.parse(#"{"type":"turn.failed","error":{"message":"Rate limited"}}"#)?.event == .failed("Rate limited"))
    }
}

struct ClaudeAuthTests {
    @Test func onlySubscriptionLoginCanSend() {
        #expect(ClaudeProvider.availability(fromAuthStatus: #"{"loggedIn": false, "authMethod": "none"}"#) != .ready)
        #expect(ClaudeProvider.availability(fromAuthStatus: #"{"loggedIn": true, "authMethod": "api_key"}"#) != .ready)
        #expect(ClaudeProvider.availability(fromAuthStatus: #"{"loggedIn": true, "authMethod": "console"}"#) != .ready)
        #expect(ClaudeProvider.availability(fromAuthStatus: "garbage") != .ready)
        #expect(ClaudeProvider.availability(fromAuthStatus: #"{"loggedIn": true, "authMethod": "claude.ai"}"#) == .ready)
    }
}
