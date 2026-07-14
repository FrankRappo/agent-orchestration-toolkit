Activate `$autopilot` and execute the grounded task to completion.

Read the project README, continuation document, current Git status, and the task-specific context
snapshot before planning. Treat the supplied context snapshot as the clarified specification only
when the owner explicitly authorized autonomous execution without further questions.

Proceed through consensus planning, durable execution, independent code review, adversarial QA,
and bounded repair loops. Use role-specialized subagents or Team only when parallelism materially
improves quality or throughput. Keep one leader responsible for integration and verification.

Safety boundaries:

- do not print or copy credentials;
- do not push or deploy to production without explicit authorization;
- do not commit raw/generated large artifacts or indexes;
- do not weaken tests, frozen benchmarks, leakage gates, or fail-closed behavior;
- do not turn uncertainty/conflicts into clean positives;
- do not launch costly/full training until dataset and benchmark gates pass;
- persist plans, state, reports, hashes, logs, and a continuation checkpoint.

Stop only after clean independent code review and UltraQA, or when an external/destructive decision
is the sole remaining blocker. Leave no accidental orphan processes; document any intentionally
detached healthy job with PID, state, log, and stop condition.
