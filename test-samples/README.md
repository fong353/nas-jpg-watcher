# 测试样本

3 个 500×500 空白 JPG，覆盖中间件的关键分支。部署后在 Windows 上跑一次就能验证工作正常。

## 文件清单

| 文件 | JFIF 状态 | 期望中间件行为 |
|---|---|---|
| `should-fix-JFIF-None-XRes300.jpg` | unit=None, XRes=300 | ✅ 命中条件 1+2 → 翻 unit 为 inches → **重命名为 `_fixed`** |
| `should-skip-no-DPI-info.jpg` | unit=None, XRes=1 | ➖ 命中条件 1 但不满足条件 2 → 跳过（保护 PS "存储为 Web"默认无 DPI 信息的合法状态）|
| `should-skip-normal-JFIF.jpg` | unit=inches, XRes=150 | ➖ 不命中条件 1 → 跳过 |

## 验证方法

把 test-samples 丢进某个在 `$Roots` 监控下的目录（或临时把 `$Roots` 指向这里），等一轮 30 分钟，或手动触发：

```powershell
powershell.exe -File scan.ps1
```

**预期结果**：
- `should-fix-JFIF-None-XRes300.jpg` → 变成 `should-fix-JFIF-None-XRes300_fixed.jpg`，JFIF unit 变成 inches，XRes 保持 300
- 另外两个文件原名不变

如果 `should-skip-no-DPI-info.jpg` 被改名了，说明条件 2 没生效 → 立刻停跑排查（这是旧版 bug，会把"无 DPI 信息"误改成"1 dpi"）。
