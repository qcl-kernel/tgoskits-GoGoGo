# Task123 一键测试入口设计

## 目标

在 `tgoskits/` 仓库根目录提供一个稳定的一键入口，使用当前机器上的真实
`qemu-system-aarch64` 和已有构建缓存，完成 Linux/StarryOS 与 RT-Thread 的 Task 1、
Task 2、Task 3 集成验证。入口不复制底层构建、启动、结果门禁或性能采集逻辑。

## 用户入口

```bash
cd tgoskits
./run-task123.sh
./run-task123.sh --long
```

默认模式为 quick，调用已有的
`os/axvisor/scripts/run_task123_guest_comparison.sh --quick`，执行两种应用客户机的
短时稳定性和功能回归。`--long` 调用同一 runner 的 `--full` 模式，执行 3600 秒长期
测试。两种模式均使用真实 QEMU，不提供 fake-QEMU 或模拟成功结果的路径。

支持的入口参数：

- `--quick`：显式选择默认短测；
- `--long`：执行 3600 秒长期测试；
- `--output DIR`：指定空的结果目录；未指定时创建 `tmp/task123-runs/<mode>-<utc>`；
- `--cache DIR`：指定构建缓存目录；
- `--allow-qemu-timer-limit`：允许 QEMU TCG timer 长尾使实时门禁降级为
  `PASS_WITH_QEMU_TIMER_LIMIT`，但不隐藏其他功能或网络失败；
- `--help`：显示用法并退出。

不使用必需的环境变量导出。脚本根据自身位置解析仓库根目录和底层 runner，调用时可从
任意当前目录启动。

## 执行流程

入口按以下顺序执行：

1. 解析参数并检查 `bash`、`qemu-system-aarch64`、`git` 及底层 runner；
2. 创建结果目录和顶层 `run.log`，记录模式、命令、时间和版本信息；
3. 传递 quick/full、cache、output 和 timer-limit 选项给已有 guest comparison runner；
4. 由已有 runner 完成 Linux/StarryOS 构建或缓存解析、AxVisor 构建、真实 QEMU 启动、
   RT-Thread 网络通信、Task 3 AI 闭环、RTBench 和宿主资源采集；
5. 保留底层 runner 的结果门禁和退出码，并在顶层输出结果目录；
6. 无论成功或失败，都保留已产生的日志和中间结果，便于定位失败阶段。

## 结果产物

结果目录至少包含底层 runner 生成的：

- `comparison/comparison.json` 和 `comparison/comparison-report.md`；
- `linux/summary.json`、`linux/rtthread.log` 及 Linux 控制台日志；
- `starryos/summary.json`、`starryos/rtthread.log` 及 StarryOS 控制台日志；
- `host-metrics.txt` 或各客户机对应的宿主资源数据；
- 顶层 `run.log`，包含入口命令和完整 stdout/stderr。

严格实时门禁失败时，脚本必须返回非零；只有显式指定
`--allow-qemu-timer-limit` 时，QEMU TCG timer 长尾才允许保留网络和功能结果并返回
底层定义的条件通过状态。该状态不等价于硬实时通过。

## 设计边界

- 入口只编排已有 runner，不修改 AxVisor、StarryOS、RT-Thread 或协议实现；
- 不自动下载依赖，不覆盖非空输出目录，不杀掉用户未创建的 QEMU 进程；
- 不把 QEMU TCG 的长尾归因于 RT-Thread 本身；报告应保留 `miss_1ms`、最大延迟和
  `PASS_WITH_QEMU_TIMER_LIMIT` 状态；
- `--long` 仅改变测试时长和请求规模，不改变客户机配置、网络拓扑或协议。

## 验证

实现后执行：

```bash
bash -n run-task123.sh
./run-task123.sh --help
./run-task123.sh --bad-option  # 必须失败且不启动 QEMU
```

随后使用当前环境运行一次默认 quick 测试，确认真实 QEMU 被调用、两个 guest 的结果
目录生成、网络/AI/RTBench 门禁执行，并检查 `git diff --check`。长测入口只进行参数和
命令映射验证，避免在开发验证阶段重复消耗 3600 秒。
