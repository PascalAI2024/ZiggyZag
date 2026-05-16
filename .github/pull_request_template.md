## Summary

-

## Verification

- [ ] `zig build`
- [ ] `zig build test`
- [ ] `.\scripts\smoke.ps1` on Windows or `./scripts/smoke.sh` on POSIX
- [ ] `.\scripts\qa-tomorrow.ps1`, if preparing a Windows friend-test build
- [ ] Manual shell smoke test, if behavior changed
- [ ] `zig build run-desktop`, if desktop behavior changed
- [ ] `zig build run-agentd -- --describe-tools`, if AgentD behavior changed

## Notes

Anything reviewers should pay attention to.
