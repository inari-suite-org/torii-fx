# torii_demo_backdoor

A **harmless** resource that behaves like a remote-code-loader backdoor so you can watch torii react.
It contacts a `.invalid` domain (reserved, never resolves) and its "payload" is a print statement.

```text
ensure torii
ensure torii_demo_backdoor        # observe mode: every attempt is logged as "WOULD BLOCK"
set torii_mode enforce
restart torii_demo_backdoor       # enforce mode: the attempts are refused
```

In observe mode attempt 5 really rewrites the demo's own manifest; the demo puts it back right after.
